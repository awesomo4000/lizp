//! Immutable source identities and expansion provenance for Lizp.
//!
//! This module contains only structured data. Runtime-owned source bytes and
//! origin records live in `Runtime`; no I/O or formatting policy is implied.

pub const Id = enum(u64) {
    none = 0,
    _,
};

pub const Span = struct {
    source: Id,
    start: u32,
    end: u32,

    pub fn isEmpty(self: Span) bool {
        return self.start == self.end;
    }

    pub fn length(self: Span) u32 {
        return self.end -| self.start;
    }
};

/// One-based line and byte-column coordinates. Byte columns keep this layer
/// independent of Unicode display-width policy; a UI may derive richer views.
pub const Point = struct {
    line: u32,
    column: u32,
};

pub const Location = struct {
    start: Point,
    end: Point,
};

pub const View = struct {
    id: Id,
    name: []const u8,
    bytes: []const u8,
};

pub const OriginId = enum(u64) {
    none = 0,
    _,
};

/// Records one lowering/expansion step. `expander` is a Lizp Symbol encoded as
/// u32 to avoid coupling this low-level module to the runtime's symbol type.
pub const ExpansionOrigin = struct {
    id: OriginId,
    expander: u32,
    call_site: Span,
    parent: ?OriginId = null,
};
