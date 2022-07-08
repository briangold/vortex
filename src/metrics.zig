const std = @import("std");

const Timespec = @import("clock.zig").Timespec;

pub fn DefaultLog2HdrHistogram(comptime T: type) type {
    // Uses the same defaults as FIO - 64 buckets per group, 29 groups
    return Log2HdrHistogram(T, 29, 64);
}

/// Tracks a metric in a high-dynamic range histogram, similar to that used in
/// Gil Tene's HdrHistogram and in the fio latency histogram.
///
/// Basic idea: We want to have finer resolution in bucket widths for smaller
/// values from T so we have smaller *relative* errors. We get this by
/// progressively widening the buckets. The tradeoffs we make are (a) we want to
/// know how to bound the relative error in a bucket, (b) we want to limit the
/// amount of memory required to store the buckets, (c) we want to limit the
/// cost of computing indexes in the buckets, and (d) we want to avoid placing
/// all the items in the largest bucket (i.e., having a poor configuration that
/// doesn't represent the true distribution well).
///
/// The scheme implemented here prioritizes (a) and (c), with moderate limits on
/// memory (b) and no consideration for (d). Other schemes, especially DDSketch,
/// may be better suited for other applications.
///
/// Implementation notes: we will form G groups of N buckets, where the buckets
/// in a given group have the same resolution. Groups 0 and 1 have precise
/// mapping, i.e. a resolution of 1 item from the domain of T. Group 2 doubles
/// the width of each bucket, group 3 doubles that, and so on.
///
/// Parametrized by:
///   T - the domain type, e.g. the type we are bucketizing
///   G - the number of bucket groups
///   N - the number of buckets per group
pub fn Log2HdrHistogram(
    comptime T: type,
    comptime G: comptime_int,
    comptime N: comptime_int,
) type {
    return struct {
        const num_buckets = G * N;
        const word_size = std.meta.bitCount(T);
        const index_bits = std.math.log2(N);
        const index_mask = N - 1;
        const IndexShift = std.meta.Int(
            .unsigned,
            std.math.log2(nextPowerOfTwoComptime(word_size, 1)),
        );

        count: usize = 0,
        sum: usize = 0,
        min: T = std.math.maxInt(T), // only valid if count > 0
        max: T = std.math.minInt(T), // only valid if count > 0
        hist: [num_buckets]usize = [_]usize{0} ** num_buckets,

        const Self = @This();

        pub fn dump(self: *const Self) void {
            std.debug.print(
                "count = {d} min = {d} max = {d} sum = {d}\n",
                .{ self.count, self.min, self.max, self.sum },
            );

            for (self.hist) |h, bi| {
                std.debug.print("hist[{d}] = {d}\n", .{ bi, h });
            }
        }

        pub fn add(self: *Self, v: T) void {
            // update scalar metrics
            self.count += 1;
            self.sum += v;
            self.min = std.math.min(self.min, v);
            self.max = std.math.max(self.max, v);

            // insert into histogram
            const idx = histogramIndex(v);
            self.hist[idx] += 1;
        }

        pub fn merge(self: *Self, other: *const Self) void {
            std.debug.assert(self.hist.len == other.hist.len);

            self.count += other.count;
            self.sum += other.sum;
            self.min = std.math.min(self.min, other.min);
            self.max = std.math.max(self.max, other.max);

            for (self.hist) |_, i| {
                self.hist[i] += other.hist[i];
            }
        }

        pub fn quantileValues(
            self: *const Self,
            comptime qs: []const comptime_float,
            res: []T,
        ) void {
            std.debug.assert(qs.len == res.len);

            var splits: [qs.len]usize = undefined;
            inline for (qs) |pct, i| {
                comptime {
                    std.debug.assert(pct >= 0.0 and pct <= 1.0);
                    std.debug.assert(i == 0 or pct >= qs[i - 1]);
                }
                splits[i] = @floatToInt(usize, pct * @intToFloat(f64, self.count));
            }

            var qi: usize = 0;
            var sum: usize = 0;
            outer: for (self.hist) |h, bi| {
                sum += h;
                while (sum >= splits[qi]) : (qi += 1) {
                    res[qi] = bucketValue(bi);

                    // std.debug.print(
                    //     "res[{d}] = {d}  bi={d} sum={d} splits[{d}]={d}\n",
                    //     .{ qi, res[qi], bi, sum, qi, splits[qi] },
                    // );

                    if (qi == splits.len - 1) break :outer;
                }
            }

            // sanity check: we must have filled in all results
            std.debug.assert(qi == splits.len - 1);
        }

        fn histogramIndex(v: T) usize {
            // Special case: group 0 and 1 are direct mapped from the value (v)
            // to the same bucket index.
            if (v < 2 * N) return v;

            // For all other cases, the most significant bit (msb) of v
            // determines the group, and the following log2(N) bits determine
            // the bucket within that group.
            //
            // NOTE: we've already handled the case of v=0, so @clz is safe to
            // run without triggering UB.

            const msb = word_size - @clz(T, v) - 1;
            const index_shift = @intCast(IndexShift, msb - index_bits);

            const group = index_shift + 1;
            if (group >= G) return num_buckets - 1;

            const index = index_mask & (v >> index_shift);

            return @as(usize, group) * N + index;
        }

        fn bucketValue(bucket: usize) T {
            std.debug.assert(bucket < num_buckets);

            // Special case: group 0 and 1 are direct mapped from the value to
            // the same bucket. We need this to avoid underflow in index_shift.
            if (bucket < 2 * N) return @intCast(T, bucket);

            // compute group and index from bucket
            const group = bucket >> index_bits;
            const index = bucket % N;

            // return midpoint of bucket
            const index_shift = @intCast(IndexShift, group - 1);
            const group_low = @intCast(T, 1) << (index_shift + index_bits);
            const bucket_low = group_low + (@intCast(T, index) << index_shift);
            const range_mid = @as(T, 1) << (index_shift - 1);
            return @intCast(T, bucket_low) + range_mid;
        }
    };
}

test "Log2HdrHistogram" {
    const S = Log2HdrHistogram(u4, 3, 4);

    // T=u4, G=3, N=4
    // v    -> trnc -> G,I   -> b  -> bv
    // 0000 -> 0000 -> G0,I0 -> 0  -> 0
    // 0001 -> 0001 -> G0,I1 -> 1  -> 1
    // 0010 -> 0010 -> G0,I2 -> 2  -> 2
    // 0011 -> 0011 -> G0,I3 -> 3  -> 3
    // 0100 -> 0100 -> G1,I0 -> 4  -> 4
    // 0101 -> 0101 -> G1,I1 -> 5  -> 5
    // 0110 -> 0110 -> G1,I2 -> 6  -> 6
    // 0111 -> 0111 -> G1,I3 -> 7  -> 7
    // 1000 -> 1000 -> G2,I0 -> 8  -> 9
    // 1001 -> 1000 -> G2,I0 -> 8  -> 9
    // 1010 -> 1010 -> G2,I1 -> 9  -> 11
    // 1011 -> 1010 -> G2,I1 -> 9  -> 11
    // 1100 -> 1100 -> G2,I2 -> 10 -> 13
    // 1101 -> 1100 -> G2,I2 -> 10 -> 13
    // 1110 -> 1110 -> G2,I3 -> 11 -> 15
    // 1111 -> 1110 -> G2,I3 -> 11 -> 15

    // mapping from value to bucket index
    try std.testing.expectEqual(@as(usize, 0), S.histogramIndex(0));
    try std.testing.expectEqual(@as(usize, 7), S.histogramIndex(7));
    try std.testing.expectEqual(@as(usize, 8), S.histogramIndex(8));
    try std.testing.expectEqual(@as(usize, 8), S.histogramIndex(9));
    try std.testing.expectEqual(@as(usize, 11), S.histogramIndex(15));

    // mapping bucket index to bucket value
    try std.testing.expectEqual(@as(usize, 0), S.bucketValue(0));
    try std.testing.expectEqual(@as(usize, 7), S.bucketValue(7));
    try std.testing.expectEqual(@as(usize, 9), S.bucketValue(8));
    try std.testing.expectEqual(@as(usize, 11), S.bucketValue(9));
    try std.testing.expectEqual(@as(usize, 15), S.bucketValue(11));

    // clamp at num_buckets
    try std.testing.expectEqual(
        @as(usize, 11),
        Log2HdrHistogram(u8, 3, 4).histogramIndex(16),
    );

    var lp = S{};

    var c: u4 = 0;
    while (c < 10) : (c += 1) {
        lp.add(c);
    }

    try std.testing.expectEqual(@as(usize, 10), lp.count);
    try std.testing.expectEqual(@as(u4, 0), lp.min);
    try std.testing.expectEqual(@as(u4, 9), lp.max);
    try std.testing.expectEqual(@as(usize, 45), lp.sum);
    try std.testing.expectEqual(@as(usize, 2), lp.hist[8]);

    const qs = [_]comptime_float{ 0.5, 0.75, 0.9 };
    var qr: [qs.len]u4 = undefined;
    lp.quantileValues(&qs, &qr);

    try std.testing.expectEqual(@as(usize, 4), qr[0]);
    try std.testing.expectEqual(@as(usize, 6), qr[1]);
    try std.testing.expectEqual(@as(usize, 9), qr[2]);

    var lp2 = S{};

    while (c != 0) : (c -= 1) {
        lp2.add(c);
    }

    try std.testing.expectEqual(@as(usize, 10), lp2.count);
    try std.testing.expectEqual(@as(u4, 1), lp2.min);
    try std.testing.expectEqual(@as(u4, 10), lp2.max);
    try std.testing.expectEqual(@as(usize, 55), lp2.sum);
    try std.testing.expectEqual(@as(usize, 2), lp2.hist[8]);

    lp.merge(&lp2);

    try std.testing.expectEqual(@as(usize, 20), lp.count);
    try std.testing.expectEqual(@as(u4, 0), lp.min);
    try std.testing.expectEqual(@as(u4, 10), lp.max);
    try std.testing.expectEqual(@as(usize, 100), lp.sum);
    try std.testing.expectEqual(@as(usize, 4), lp.hist[8]);

    lp.quantileValues(&qs, &qr);

    try std.testing.expectEqual(@as(usize, 5), qr[0]);
    try std.testing.expectEqual(@as(usize, 7), qr[1]);
    try std.testing.expectEqual(@as(usize, 9), qr[2]);
}

test "DefaultLog2HdrHistogram" {
    const S = DefaultLog2HdrHistogram(u63);

    try std.testing.expectEqual(@as(u63, 0), S.bucketValue(0));
    try std.testing.expectEqual(@as(u63, 40704), S.bucketValue(655));
}

// Small helper to find the next power-of-two above some minimum, but unlike
// std.math.ceilPowerOfTwo, works on comptime_int so we can build an Int type
// from the returned bit count.
fn nextPowerOfTwoComptime(
    comptime v: comptime_int,
    comptime min: comptime_int,
) comptime_int {
    std.debug.assert(v > 0);
    std.debug.assert(v <= 64);

    var p: comptime_int = min;
    inline while (p < v) p <<= 1;

    return p;
}

test "nextPowerOfTwoComptime" {
    // turn a u1 into a u8
    try std.testing.expectEqual(8, nextPowerOfTwoComptime(1, 8));

    // a u8 should just be a u8
    try std.testing.expectEqual(8, nextPowerOfTwoComptime(8, 8));

    // etc.
    try std.testing.expectEqual(16, nextPowerOfTwoComptime(9, 8));
    try std.testing.expectEqual(16, nextPowerOfTwoComptime(16, 8));
    try std.testing.expectEqual(32, nextPowerOfTwoComptime(17, 8));
    try std.testing.expectEqual(32, nextPowerOfTwoComptime(32, 8));
    try std.testing.expectEqual(64, nextPowerOfTwoComptime(33, 8));
    try std.testing.expectEqual(64, nextPowerOfTwoComptime(64, 8));
}
