# Metron

Metron is a Zig library for writing micro-benchmarks, similar to the [Google
Benchmark](https://github.com/google/benchmark) library for C++.

## Quickstart

To benchmark a function:

```zig
fn someFunction(n: usize) usize {
    // compute something interesting
}
```

define a `struct` that acts as a test specification, and pass that to
`metron.run()` to evaluate:

```zig
pub fn main() anyerror!void {
    try metron.run(struct {
        pub const name = "someFunction";
        pub const args = [_]usize{ 1, 2, 5, 10 };

        pub fn run(state: *State, n: usize) void {
            var iter = state.iter();
            while (iter.next()) |i| {
                std.mem.doNotOptimizeAway(i);
                const res = someFunction(n);
                std.mem.doNotOptimizeAway(res);
            }
        }
    });
}
```

The Metron test runner will iterate over all the `args` values defined in the
specification, and it will invoke the `run` function with a `state` object that
controls the work loop with an iterator. The state iterator will take care of
measuring time and counting loop iterations to get an accurate measurement of
how long `someFunction` takes per call.

To learn more about the features and details of Metron, see the [guided
tour](tour/README.md), which can be built by `zig build tour`.

## Example output

Clone this repository and use a recent Zig binary to build the included tour.
On my M1 Macbook Pro:

```console
$ zig build tour -Drelease-fast=true   # Build samples
$ ./zig-out/bin/cache                  # Run the "cache" benchmark
---------------------------------------
Benchmark           Time     Iterations
---------------------------------------
cache/8k          181 ns        7063207 rate=42.128GiB/s
cache/16k         357 ns        3904645 rate=42.771GiB/s
cache/32k         705 ns        1999910 rate=43.300GiB/s
cache/64k        1401 ns         989538 rate=43.565GiB/s
cache/128k       2864 ns         482850 rate=42.619GiB/s
cache/256k       6641 ns         213369 rate=36.760GiB/s
cache/512k      16396 ns          85416 rate=29.780GiB/s
cache/1M        38948 ns          36251 rate=25.073GiB/s
cache/2M        87455 ns          15797 rate=22.333GiB/s
cache/4M       195175 ns           7211 rate=20.014GiB/s
cache/8M       447614 ns           3082 rate=17.454GiB/s
cache/16M     1367896 ns           1061 rate=11.423GiB/s
cache/32M     5410721 ns            269 rate=5.776GiB/s
cache/64M    17845938 ns             75 rate=3.502GiB/s
```

This benchmark is modeled after Chandler Carruth's [CppCon 2017
talk](https://www.youtube.com/watch?v=2EWejmkKlxs), and shows that you can
(roughly) derive the organization of your CPU cache hierarchy by writing a
benchmark. Except you have to be careful of the compiler and the hardware trying
to outsmart your test. See the [full code](tour/cache.zig).

## Other benchmarking libraries for Zig

There are a number of alternatives worth considering. 

- https://github.com/Hejsil/zig-bench
- https://github.com/dweiller/zubench

Please let me know if there are others I've missed.

## Roadmap

- [ ] JSON output
- [ ] Report additional machine context (CPU, OS, etc.)
- [ ] Perf counter integration on Linux
- [ ] Support repetition and aggregate output
- [ ] Support non-rate custom counters
- [ ] Library of system microbenchmarks (a la lmbench)