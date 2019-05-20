open Core_kernel
open Async
module Amqp = Amqp_client_async

let now () = Unix.gettimeofday () |> Int.of_float

let timer_ms () =
  let start_ts = Time.now () in
  fun () ->
    let end_ts = Time.now () in
    Time.diff end_ts start_ts |> Time.Span.to_ms |> int_of_float

module Percentile = struct
  type ts = int

  type value = int

  type t = {
    period : int;
    percentiles : float list;
    mutable total_observations : int;
    mutable sum : value;
    mutable observations : (value * ts) list (* Ordered by timestamp *)
  }

  let init ~period ~percentiles =
    {period; percentiles; total_observations = 0; sum = 0; observations = []}

  let expire ~now t =
    t.observations
    <- List.take_while ~f:(fun (_, ts) -> ts + t.period >= now) t.observations

  let average observations =
    match Array.length observations with
    | 0 -> 0
    | n -> Array.fold ~init:0 ~f:( + ) observations / n

  let make_percentile_key period value = Printf.sprintf "percentiles.%ds.%s" period value

  let make_percentile_key_float period percentile =
    Printf.sprintf "%.2f" percentile
    |> String.tr ~target:'.' ~replacement:'_'
    |> make_percentile_key period

  let get_stats ~now t =
    expire ~now t;
    let sorted_observations =
      let observations = Array.of_list_map ~f:fst t.observations in
      Array.sort ~compare:Int.compare observations;
      observations
    in
    let observation_count = Array.length sorted_observations in
    let get_percentile_value percentile =
      match observation_count with
      | 0 -> 0 (* Default to zero if there no observations *)
      | n ->
          let ceil_index =
            percentile *. Float.of_int n /. 100.0 |> Float.round_up |> Int.of_float
          in
          sorted_observations.(ceil_index - 1)
    in
    let percentile_values =
      List.map t.percentiles ~f:(fun percentile ->
          make_percentile_key_float t.period percentile, get_percentile_value percentile
      )
    in
    ("sum", t.sum)
    :: ("observations", t.total_observations)
    :: (make_percentile_key t.period "observations", observation_count)
    :: (make_percentile_key t.period "avg", average sorted_observations)
    :: percentile_values

  let add_observation t ~now value =
    t.observations <- (value, now) :: t.observations;
    t.total_observations <- t.total_observations + 1;
    t.sum <- t.sum + value
end

type t = {
  channel : Amqp.Channel.no_confirm Amqp.Channel.t;
  exchange : [`Topic of string] Amqp.Exchange.t;
  prefix : string;
  metrics : (string, int) Hashtbl.t;
  percentile_period : int;
  (* At some point we should allow multiple periods *)
  percentiles : float list;
  percentile_data : (string, Percentile.t) Hashtbl.t;
  init_time : Time.t
}

type stat = {
  path : string;
  value : int;
  ts : int
}

let send_raw t stats =
  let msg =
    stats
    |> List.map ~f:(fun stat ->
           Printf.sprintf "%s.%s %d %d" t.prefix stat.path stat.value stat.ts )
    |> String.concat ~sep:"\n"
  in
  Amqp.Exchange.publish
    t.channel
    t.exchange
    ~routing_key:"graphite"
    (Amqp.Message.make msg)
  >>= fun `Ok -> return ()

let send t () =
  let now = now () in
  Hashtbl.fold t.percentile_data ~init:[] ~f:(fun ~key ~data:fractile acc ->
      Percentile.get_stats ~now fractile
      |> List.fold ~init:acc ~f:(fun acc (k, v) ->
             {path = Printf.sprintf "%s.%s" key k; value = v; ts = now} :: acc ) )
  |> (fun acc ->
       Hashtbl.fold t.metrics ~init:acc ~f:(fun ~key ~data acc ->
           {path = key; value = data; ts = now} :: acc ) )
  |> send_raw t

let flush t = send t ()

module Report = struct
  type metric = {
    observations : int;
    obs_rate : float;
    rate : float option;
    avg : float option;
    sum : int option
  }
  [@@deriving show]

  type t = (string * metric) list [@@deriving show]
end

let report t =
  let time_since_init = Time.diff (Time.now ()) t.init_time in
  let percentile_data =
    t.percentile_data
    |> Hashtbl.to_alist
    |> List.map ~f:(fun (key, fractile) ->
           ( key,
             Report.
               { observations = fractile.Percentile.total_observations;
                 obs_rate =
                   Float.(
                     of_int fractile.Percentile.total_observations
                     / Time.Span.to_sec time_since_init);
                 rate =
                   Some
                     Float.(
                       of_int fractile.Percentile.sum / Time.Span.to_sec time_since_init);
                 avg =
                   Some
                     Float.(
                       of_int fractile.Percentile.sum
                       / of_int fractile.Percentile.total_observations);
                 sum = Some fractile.Percentile.sum } ) )
  in
  let metric_data =
    t.metrics
    |> Hashtbl.to_alist
    |> List.map ~f:(fun (key, metric) ->
           ( key,
             Report.
               { observations = metric;
                 obs_rate = Float.of_int metric /. Time.Span.to_sec time_since_init;
                 rate = None;
                 avg = None;
                 sum = None } ) )
  in
  percentile_data @ metric_data

let init ?(updates_per_minute = 2) ?(percentile_period = 60)
    ?(percentiles = [50.; 90.; 95.; 99.]) ~prefix connection
  =
  let%bind channel =
    Amqp.Connection.open_channel ~id:"graphite" Amqp.Channel.no_confirm connection
  in
  let%bind exchange =
    Amqp.Exchange.declare ~durable:true channel Amqp.Exchange.topic_t "metrics"
  in
  let t =
    { channel;
      exchange;
      prefix;
      metrics = Hashtbl.Poly.create ();
      percentile_period;
      percentiles;
      percentile_data = Hashtbl.Poly.create ();
      init_time = Time.now () }
  in
  (* Start the sender *)
  let send_frequency = Time.Span.of_int_sec (60 / updates_per_minute) in
  Clock.every' send_frequency (send t);
  return t

let incr ?by ~key t = Hashtbl.incr ?by t.metrics key

let decr t ~key value = Hashtbl.decr ~by:value t.metrics key

let incr_opt ?by ~key t = Option.iter t ~f:(fun t -> incr t ~key ?by)

let decr_opt t ~key value = Option.iter t ~f:(fun t -> decr t ~key value)

let set t ~key value = Hashtbl.set t.metrics ~key ~data:value

let remove t ~key = Hashtbl.remove t.metrics key

let add_percentile_observation t ~key value =
  Hashtbl.find_or_add t.percentile_data key ~default:(fun () ->
      Percentile.init ~period:t.percentile_period ~percentiles:t.percentiles )
  |> fun f -> Percentile.add_observation f ~now:(now ()) value

let add_percentile_observation_opt t ~key value =
  match t with
  | None -> ()
  | Some t -> add_percentile_observation t ~key value

module Result = struct
  let time ?graphite ~key ~f v =
    let timer = timer_ms () in
    let%bind r = f v in
    let sub_key =
      match r with
      | Ok _ -> "ok"
      | Error _ -> "error"
    in
    add_percentile_observation_opt
      graphite
      ~key:(Printf.sprintf "%s.%s" key sub_key)
      (timer ());
    return r
end

module Option = struct
  let time ?graphite ~key ~f v =
    let timer = timer_ms () in
    let%bind r = f v in
    let sub_key =
      match r with
      | Some _ -> "ok"
      | None -> "error"
    in
    add_percentile_observation_opt
      graphite
      ~key:(Printf.sprintf "%s.%s" key sub_key)
      (timer ());
    return r
end

module Deferred = struct
  let time ?graphite ~key ~f v =
    let timer = timer_ms () in
    let%bind r = f v in
    add_percentile_observation_opt graphite ~key:(Printf.sprintf "%s.ok" key) (timer ());
    return r

  let keyed_time ?graphite ~key ~f v =
    let timer = timer_ms () in
    let%bind chunk, r = f v in
    add_percentile_observation_opt
      graphite
      ~key:(Printf.sprintf "%s.%s" key chunk)
      (timer ());
    return r
end
