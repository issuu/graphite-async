0.14.2
======

* Add support for callback functionality on timing functions.

0.14.1
======

* Do not lock dependencies to versions in advance. In particular the
  `ppx_deriving` lockdown prevents use of OCaml 4.08.

0.14.0
======

* Expose `flush` endpoint to flush queued message to graphite

0.13.2
======

* Add `Deferred.keyed_time` to allow deferred to decide on part of the key
  string. Useful for logging per status code or similar.

0.13.1
======

* Drop upper version constraints on Jane Street packages

0.13.0
======

* Add `sum` to report
* Add `obs_rate` to report. Shows the rate of observations.
* `rate` now shows the rate of change in percentile sums.

0.12.0
======

* Fix percentile reports reporting sums as observations.
* Add `avg` to percentiles in reports.

0.11.0
======

* Add Graphite.Report module to generate reports for easy printing

0.10.0
======

* Add interface to make irrelevant contents private

0.9.0
=====

* Initial extraction into a library
* Convert from OUnit2 to alcotest
