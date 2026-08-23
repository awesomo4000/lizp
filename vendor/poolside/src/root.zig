//! Generational handle pools for Zig.

pub const Options = @import("pool.zig").Options;
pub const Pool = @import("pool.zig").Pool;
pub const PoolWithOptions = @import("pool.zig").PoolWithOptions;
pub const TaggedPool = @import("pool.zig").TaggedPool;
pub const TaggedPoolWithOptions = @import("pool.zig").TaggedPoolWithOptions;
pub const visitHandles = @import("reflect.zig").visitHandles;

test {
    _ = @import("pool.zig");
    _ = @import("reflect.zig");
}
