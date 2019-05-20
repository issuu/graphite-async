open Core_kernel
module Percentile = Graphite_async.Percentile

(* Should have tests for the fractal part *)

let assert_stats ?(percentiles = []) ~now ?total_obs ?avg ?sum ?period_obs t =
  let value ~name stats = List.Assoc.find ~equal:String.equal stats name in
  let stats = Percentile.get_stats t ~now in
  let percentile_key percentile =
    let p = Printf.sprintf "%.2f" percentile |> String.tr ~target:'.' ~replacement:'_' in
    Printf.sprintf "percentiles.60s.%s" p
  in
  let assert_value ~name expected =
    Alcotest.(check (option int)) name expected (value ~name stats)
  in
  assert_value ~name:"observations" total_obs;
  assert_value ~name:"percentiles.60s.avg" avg;
  assert_value ~name:"sum" sum;
  assert_value ~name:"percentiles.60s.observations" period_obs;
  List.iter percentiles ~f:(fun (percentile, value) ->
      assert_value ~name:(percentile_key percentile) value );
  Alcotest.(check int)
    "Too many percentiles returned"
    (List.length percentiles)
    (List.length stats - 4)

let test_empty_fractile () =
  let t = Percentile.init ~period:60 ~percentiles:[50.; 100.] in
  assert_stats
    t
    ~now:0
    ~total_obs:0
    ~avg:0
    ~sum:0
    ~period_obs:0
    ~percentiles:[50., Some 0; 100., Some 0]

let test_fractiles () =
  let t = Percentile.init ~period:60 ~percentiles:[50.; 100.] in
  Percentile.add_observation t ~now:10 1;
  Percentile.add_observation t ~now:20 2;
  Percentile.add_observation t ~now:30 3;
  Percentile.add_observation t ~now:40 4;
  Percentile.add_observation t ~now:50 5;
  assert_stats
    t
    ~now:60
    ~total_obs:5
    ~avg:3
    ~sum:15
    ~period_obs:5
    ~percentiles:[50., Some 3; 100., Some 5];
  assert_stats
    t
    ~now:90
    ~total_obs:5
    ~avg:4
    ~sum:15
    ~period_obs:3
    ~percentiles:[50., Some 4; 100., Some 5];
  assert_stats
    t
    ~now:120
    ~total_obs:5
    ~avg:0
    ~sum:15
    ~period_obs:0
    ~percentiles:[50., Some 0; 100., Some 0];
  (* Test adding old observations only adds to the summary *)
  Percentile.add_observation t ~now:30 3;
  Percentile.add_observation t ~now:40 4;
  Percentile.add_observation t ~now:50 5;
  assert_stats
    t
    ~now:120
    ~total_obs:8
    ~avg:0
    ~sum:27
    ~period_obs:0
    ~percentiles:[50., Some 0; 100., Some 0];
  Percentile.add_observation t ~now:100 3;
  Percentile.add_observation t ~now:100 4;
  Percentile.add_observation t ~now:100 5;
  let percentiles = [50., Some 4; 100., Some 5] in
  assert_stats t ~now:120 ~total_obs:11 ~avg:4 ~sum:39 ~period_obs:3 ~percentiles;
  (* Calling again with the same timestamp should yeild the same stats *)
  assert_stats t ~now:120 ~total_obs:11 ~avg:4 ~sum:39 ~period_obs:3 ~percentiles

let test_set =
  [ Alcotest.test_case "test fractile with no observations" `Quick test_empty_fractile;
    Alcotest.test_case "test fractiles" `Quick test_fractiles ]

let () = Alcotest.run Caml.__MODULE__ ["test_set", test_set]
