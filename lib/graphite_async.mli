open Core_kernel
open Async_kernel
module Amqp = Amqp_client_async

module Percentile : sig
  type ts = int

  type value = int

  type t

  val init : period:int -> percentiles:float list -> t

  val average : int Array.t -> int

  val get_stats : now:int -> t -> (string * value) list

  val add_observation : t -> now:ts -> value -> unit
end

type t

module Report : sig
  type metric [@@deriving show]

  type t = (string, metric) List.Assoc.t [@@deriving show]
end

val init_mock
  : ?percentile_period:int ->
    ?percentiles:float list ->
    unit ->
    t

val init
  :  ?updates_per_minute:int ->
  ?percentile_period:int ->
  ?percentiles:float list ->
  prefix:string ->
  Amqp.Connection.t ->
  t Deferred.t

val incr : ?by:int -> key:string -> t -> unit

val decr : t -> key:string -> int -> unit

val incr_opt : ?by:int -> key:string -> t Option.t -> unit

val decr_opt : t Option.t -> key:string -> int -> unit

val set : t -> key:string -> int -> unit

val remove : t -> key:string -> unit

val add_percentile_observation : t -> key:string -> Percentile.value -> unit

val add_percentile_observation_opt : t option -> key:string -> Percentile.value -> unit

val report : t -> Report.t

val flush : t -> unit Deferred.t

module Result : sig
  val time
    :  ?graphite:t ->
    ?callback:(Time.Span.t -> 'a -> ('b, 'c) Result.t -> unit) ->
    key:string ->
    f:('a -> ('b, 'c) Deferred.Result.t) ->
    'a ->
    ('b, 'c) Deferred.Result.t
end

module Option : sig
  val time
    :  ?graphite:t ->
    ?callback:(Time.Span.t -> 'a -> 'b option -> unit) ->
    key:string ->
    f:('a -> 'b option Deferred.t) ->
    'a ->
    'b option Deferred.t
end

module Deferred : sig
  val time
    :  ?graphite:t ->
    ?callback:(Time.Span.t -> 'a -> 'b -> unit) ->
    key:string ->
    f:('a -> 'b Deferred.t) ->
    'a ->
    'b Deferred.t

  val keyed_time
    :  ?graphite:t ->
    ?callback:(Time.Span.t -> 'a -> string * 'b -> unit) ->
    key:string ->
    f:('a -> (string * 'b) Deferred.t) ->
    'a ->
    'b Deferred.t
end
