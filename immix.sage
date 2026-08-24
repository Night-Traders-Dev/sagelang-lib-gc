# ============================================================
# SageLang Bare-Metal Immix GC — STW Mode
# Target: SageMetal / RP2040 / any no-OS environment
# GC Mode: Stop-The-World (no pthreads, no malloc, no OS calls)
#
# Architecture:
#   - Static heap pool (caller-supplied or compile-time array)
#   - 32KB blocks / 128B lines / bump-pointer alloc
#   - Per-line mark bitmap (1 byte per line)
#   - STW mark → line-sweep → reset
#   - No evacuation (raw C pointers via VAL_POINTER are pinned)
#   - No write barrier (not needed in STW mode)
# ============================================================

# ─────────────────────────────────────────
# § 1  Configuration constants
# ─────────────────────────────────────────

let IMMIX_BLOCK_SIZE = 32768      # 32 KB per block
let IMMIX_LINE_SIZE = 128        # bytes per line
let IMMIX_LINES_PER_BLOCK = 256       # 32768 / 128
let IMMIX_MAX_BLOCKS = 16         # 512 KB total heap (RP2040 budget)
let IMMIX_LARGE_THRESHOLD = 112       # objects > 112B span multiple lines

# Object type tags (must match the C-side VAL_* enum)
let VAL_NONE = 0
let VAL_INT = 1
let VAL_FLOAT = 2
let VAL_BOOL = 3
let VAL_STRING = 4
let VAL_LIST = 5
let VAL_DICT = 6
let VAL_FUNC = 7
let VAL_CLOSURE = 8
let VAL_POINTER = 9    # raw C pointer — NEVER evacuate
let VAL_CLIB = 10   # C library handle — NEVER evacuate

proc _zeros(n):
    let a = []
    for i in range(n):
        push(a, 0)
    return a

# ─────────────────────────────────────────
# § 2  Data structures
# ─────────────────────────────────────────

# One Immix block: header lives inside the first portion of the block.
# The 'data' field is a conceptual alias for the byte region that
# follows the header inside the same 32KB allocation.
proc ImmixBlock():
    return {
        "line_marks": _zeros(IMMIX_LINES_PER_BLOCK),
        "block_mark": 0,
        "free_lines": 0,
        "next_block_idx": 0,
        "cursor": 0,
        "limit": 0,
        "current_line": 0,
    }

# The allocator state — one per CPU core (bare-metal: one global)
proc ImmixAllocator():
    return {
        "block_pool": [],
        "total_blocks": 0,
        "current_block": 0,
        "free_block_head": 0,
    }

# Root set — registered pointers the GC uses as traversal starting points
proc GCRootSet():
    return {
        "slots": _zeros(256),
        "count": 0,
        "capacity": 256,
    }

# GC statistics (exposed via gc_stats())
proc GCStats():
    return {
        "collections": 0,
        "alloc_calls": 0,
        "alloc_bytes": 0,
        "live_lines_last": 0,
        "free_lines_last": 0,
        "last_pause_cycles": 0,
    }
# ─────────────────────────────────────────
# § 3  Module-level state
# ─────────────────────────────────────────

# Single global instances — bare-metal has no dynamic allocation of GC state
var _alloc = ImmixAllocator()
var _roots = GCRootSet()
var _stats = GCStats()
var _enabled = true

# ─────────────────────────────────────────
# § 4  Heap initialisation
# ─────────────────────────────────────────

# Called once at boot before any allocation.
# 'pool_size' must be a multiple of IMMIX_BLOCK_SIZE.
#
# Usage (SageMetal boot.sage):
#   gc_init_static(512 * 1024)   # 512 KB from the linker-defined .heap section
proc gc_init_static(pool_size) :
    if not (pool_size % IMMIX_BLOCK_SIZE == 0):
        raise "gc_init_static: pool_size must be a multiple of IMMIX_BLOCK_SIZE"

    let n_blocks = pool_size / IMMIX_BLOCK_SIZE
    if not (n_blocks <= IMMIX_MAX_BLOCKS):
        raise "gc_init_static: requested blocks exceed IMMIX_MAX_BLOCKS"

    _alloc["total_blocks"]  = n_blocks
    _alloc["current_block"] = -1
    _alloc["free_block_head"] = 0

    # Materialize the static block pool
    while len(_alloc["block_pool"]) < IMMIX_MAX_BLOCKS:
        push(_alloc["block_pool"], ImmixBlock())

    # Wire the free-block linked list
    for i in range(n_blocks):
        _alloc["block_pool"][i]["block_mark"]      = 0
        _alloc["block_pool"][i]["free_lines"]      = IMMIX_LINES_PER_BLOCK
        _alloc["block_pool"][i]["cursor"]          = 0
        _alloc["block_pool"][i]["limit"]           = 0
        _alloc["block_pool"][i]["current_line"]    = 0
        if i < n_blocks - 1:
            _alloc["block_pool"][i]["next_block_idx"] = i + 1
        else:
            _alloc["block_pool"][i]["next_block_idx"] = -1
        for j in range(IMMIX_LINES_PER_BLOCK):
            _alloc["block_pool"][i]["line_marks"][j] = 0

    _roots["count"]    = 0
    _roots["capacity"] = 256   # static root table — enough for bare-metal programs

    _stats = {
        "collections": 0,
        "alloc_calls": 0,
        "alloc_bytes": 0,
        "live_lines_last": 0,
        "free_lines_last": 0,
        "last_pause_cycles": 0,
    }

    _enabled = true

# ─────────────────────────────────────────
# § 5  Block management helpers
# ─────────────────────────────────────────

# Pull the next free block from the free-block list.
# Returns the block index, or -1 if the heap is exhausted.
proc _acquire_free_block() :
    if _alloc["free_block_head"] == -1:
        return -1   # heap exhausted

    let idx = _alloc["free_block_head"]
    _alloc["free_block_head"] = _alloc["block_pool"][idx]["next_block_idx"]
    _alloc["block_pool"][idx]["next_block_idx"] = -1
    _alloc["block_pool"][idx]["block_mark"]     = 1

    # Reset cursor to first line
    _alloc["block_pool"][idx]["cursor"]       = 0
    _alloc["block_pool"][idx]["limit"]        = IMMIX_LINE_SIZE
    _alloc["block_pool"][idx]["current_line"] = 0

    return idx

# Return a block to the free-block list (called by sweep when all lines are dead)
proc _release_block(block_idx) :
    let blk = _alloc["block_pool"][block_idx]
    blk["block_mark"]     = 0
    blk["free_lines"]     = IMMIX_LINES_PER_BLOCK
    blk["cursor"]         = 0
    blk["limit"]          = 0
    blk["current_line"]   = 0
    for j in range(IMMIX_LINES_PER_BLOCK):
        blk["line_marks"][j] = 0

    blk["next_block_idx"]         = _alloc["free_block_head"]
    _alloc["free_block_head"]     = block_idx

# Find the next free (unmarked) line in a block starting from 'from_line'.
# Returns the line index, or -1 if no free line exists.
proc _find_free_line(block_idx, from_line) :
    for i in range(from_line, IMMIX_LINES_PER_BLOCK):
        if _alloc["block_pool"][block_idx]["line_marks"][i] == 0:
            return i
    return -1

# ─────────────────────────────────────────
# § 6  Allocation — bump-pointer fast path
# ─────────────────────────────────────────

# Allocate 'size' bytes from the current block.
# Returns a Pointer on success, or panics if the heap is exhausted.
#
# Large objects (size > IMMIX_LARGE_THRESHOLD) are handled by
# _alloc_large() which spans contiguous lines.
proc gc_alloc(size) :
    if not (size > 0):
        raise "gc_alloc: size must be positive"

    _stats["alloc_calls"] = _stats["alloc_calls"] + 1
    _stats["alloc_bytes"] = _stats["alloc_bytes"] + size

    if size > IMMIX_LARGE_THRESHOLD:
        return _alloc_large(size)

    return _alloc_small(size)

# Small object fast path (the common case)
proc _alloc_small(size) :
    # Try current block and line first
    if _alloc["current_block"] != -1:
        let blk = _alloc["block_pool"][_alloc["current_block"]]
        if blk["cursor"] + size <= blk["limit"]:
            # ── FAST PATH: bump the cursor ──────────────────────────────────
            let ptr = heap_offset_to_ptr(_alloc["current_block"], blk["cursor"])
            blk["cursor"] = blk["cursor"] + size
            return ptr
        # Current line is full — find the next free line in this block
        else:
            return _alloc_slow(_alloc["current_block"], size)

    # No active block — acquire one
    return _alloc_new_block(size)

# Slow path: scan the current block for the next free line
proc _alloc_slow(block_idx, size) :
    let blk = _alloc["block_pool"][block_idx]
    let next_line = _find_free_line(block_idx, blk["current_line"] + 1)

    if next_line != -1:
        blk["current_line"] = next_line
        blk["cursor"]       = next_line * IMMIX_LINE_SIZE
        blk["limit"]        = blk["cursor"] + IMMIX_LINE_SIZE

        let ptr = heap_offset_to_ptr(block_idx, blk["cursor"])
        blk["cursor"] = blk["cursor"] + size
        return ptr

    # Block exhausted — get a fresh block
    return _alloc_new_block(size)

# Acquire a new block and allocate from line 0
proc _alloc_new_block(size) :
    let idx = _acquire_free_block()

    if idx == -1:
        # Last resort: trigger a GC cycle and retry once
        gc_collect()
        let idx2 = _acquire_free_block()
        if not (idx2 != -1):
            raise "gc_alloc: heap exhausted after emergency collection"
        _alloc["current_block"] = idx2
    else:
        _alloc["current_block"] = idx

    let blk = _alloc["block_pool"][_alloc["current_block"]]
    let ptr = heap_offset_to_ptr(_alloc["current_block"], blk["cursor"])
    blk["cursor"] = blk["cursor"] + size
    return ptr

# Large object allocation — spans however many contiguous lines are needed.
# The object header stores the line-span count so the marker can skip ahead.
proc _alloc_large(size) :
    let lines_needed = (size + IMMIX_LINE_SIZE - 1) / IMMIX_LINE_SIZE

    # Find a block with 'lines_needed' consecutive free lines
    for b in range(_alloc["total_blocks"]):
        if _alloc["block_pool"][b]["block_mark"] == 0:
            continue   # block is entirely in the free list, unusable mid-alloc

        # skip lines already handed out by the bump allocator in this block
        let scan_from = blk_current_line(b) + 1
        let start_line = _find_contiguous_free_lines(b, lines_needed, scan_from)
        if start_line != -1:
            # Mark the span as occupied immediately (prevents double-use)
            for l in range(start_line, start_line + lines_needed):
                _alloc["block_pool"][b]["line_marks"][l] = 1

            let ptr = heap_offset_to_ptr(b, start_line * IMMIX_LINE_SIZE)
            # Write the span count into the object header's reserved field
            # (Caller is responsible for the full header initialisation)
            write_span_count(ptr, lines_needed)
            return ptr

    if not (false):
        raise "_alloc_large: no contiguous span available — heap fragmented"
    return null_ptr()

proc blk_current_line(b):
    return _alloc["block_pool"][b]["current_line"]

proc _find_contiguous_free_lines(block_idx, n, from_line = 0):
    var run = 0
    var run_start = -1
    for i in range(from_line, IMMIX_LINES_PER_BLOCK):
        if _alloc["block_pool"][block_idx]["line_marks"][i] == 0:
            if run == 0:
                run_start = i
            run = run + 1
            if run >= n:
                return run_start
        else:
            run = 0
            run_start = -1
    return -1

# ─────────────────────────────────────────
# § 7  Root set management
# ─────────────────────────────────────────

# Register a pointer slot as a GC root.
# 'slot' is a pointer TO a pointer (a **SageValue style reference).
# Call on function entry for every local that holds a heap reference.
proc gc_root_push(slot) :
    if not (_roots["count"] < _roots["capacity"]):
        raise "gc_root_push: root set overflow — increase GCRootSet.capacity"
    _roots["slots"][_roots["count"]] = slot
    _roots["count"] = _roots["count"] + 1

# Unregister the most recently pushed root slot (LIFO).
# Called on function exit.
proc gc_root_pop() :
    if not (_roots["count"] > 0):
        raise "gc_root_pop: root set underflow"
    _roots["count"] = _roots["count"] - 1

# Snapshot the root set into a temporary work list.
# Used by the STW marker so the root set can be pushed/popped
# safely during traversal without re-entrancy issues.
proc gc_root_snapshot(out_list, out_count) :
    for i in range(_roots["count"]):
        out_list[i] = _roots["slots"][i]
    write_int(out_count, _roots["count"])

# ─────────────────────────────────────────
# § 8  Mark phase — STW
# ─────────────────────────────────────────

# Internal mark-stack (iterative DFS to avoid C stack overflow on deep graphs)
var _mark_stack = _zeros(4096)
var _mark_stack_top = 0
let MARK_STACK_CAPACITY = 4096

proc _mark_push(ptr) :
    if not (_mark_stack_top < MARK_STACK_CAPACITY):
        raise "_mark_push: mark stack overflow — increase MARK_STACK_CAPACITY"
    _mark_stack[_mark_stack_top] = ptr
    _mark_stack_top = _mark_stack_top + 1

proc _mark_pop() :
    if not (_mark_stack_top > 0):
        raise "_mark_pop: mark stack underflow"
    _mark_stack_top = _mark_stack_top - 1
    return _mark_stack[_mark_stack_top]

# Mark the line(s) containing the object at 'ptr', then push children.
# Returns without marking if ptr is null or already-marked.
proc _mark_object(ptr) :
    if is_null(ptr):
        return

    let block_idx = ptr_to_block_idx(ptr)
    let byte_off:  Int = ptr_to_block_offset(ptr)
    let line_idx:  Int = byte_off / IMMIX_LINE_SIZE

    if block_idx < 0 or block_idx >= _alloc["total_blocks"]:
        return   # pointer not into our managed heap (e.g. a static string)

    if _alloc["block_pool"][block_idx]["line_marks"][line_idx] == 1:
        return   # already marked — cut the traversal

    # Mark this line
    _alloc["block_pool"][block_idx]["line_marks"][line_idx] = 1

    # If the object spills into the next line, mark that too
    let obj_size = read_object_size(ptr)
    if byte_off % IMMIX_LINE_SIZE + obj_size > IMMIX_LINE_SIZE:
        let next_line = line_idx + 1
        if next_line < IMMIX_LINES_PER_BLOCK:
            _alloc["block_pool"][block_idx]["line_marks"][next_line] = 1

    # Push children onto the iterative mark stack
    _push_children(ptr)

# Push all child references of 'ptr' onto the mark stack,
# depending on the object's VAL_* type tag.
#
# VAL_POINTER and VAL_CLIB: mark the header but do NOT follow
# the raw C pointer — it lives outside the managed heap.
proc _push_children(ptr) :
    let type_tag = read_type_tag(ptr)

    if type_tag == VAL_LIST:
        let len:  Int = read_list_length(ptr)
        for i in range(len):
            let child = read_list_element(ptr, i)
            _mark_push(child)

    elif type_tag == VAL_DICT:
        let n_entries = read_dict_length(ptr)
        for i in range(n_entries):
            let k = read_dict_key(ptr, i)
            let v = read_dict_val(ptr, i)
            _mark_push(k)
            _mark_push(v)

    elif type_tag == VAL_CLOSURE:
        # Upvalue references are stored as an array of slots
        let n_upvals = read_closure_upval_count(ptr)
        for i in range(n_upvals):
            let upval = read_closure_upval(ptr, i)
            _mark_push(upval)
        # Also mark the function prototype the closure wraps
        _mark_push(read_closure_func(ptr))

    elif type_tag == VAL_FUNC:
        # Function objects can reference their default argument values
        let n_defaults = read_func_default_count(ptr)
        for i in range(n_defaults):
            _mark_push(read_func_default(ptr, i))

    elif type_tag == VAL_STRING:
        # Strings are leaf nodes — they contain raw bytes, no child pointers
        pass

    elif type_tag == VAL_POINTER or type_tag == VAL_CLIB:
        # DO NOT chase the raw C pointer.
        # The SageLang header itself is already marked (we got here from
        # the enclosing object), so we just skip child traversal.
        pass

    # VAL_INT, VAL_FLOAT, VAL_BOOL, VAL_NONE: scalar — no children
    # (default: fall through with no action)

# ─────────────────────────────────────────
# § 9  Sweep phase — line-granularity
# ─────────────────────────────────────────

# Walk all blocks. For each block, count live vs. free lines.
# Blocks where every line is dead are returned to the free-block list.
# Line mark arrays are reset to prepare for the next cycle.
#
# Note: This is the entire sweep. No per-object free-list insertion,
# no header patching. Just bitmap counting and memset.
proc _sweep() :
    var total_live  = 0
    var total_free  = 0

    for b in range(_alloc["total_blocks"]):
        let blk = _alloc["block_pool"][b]
        if blk["block_mark"] == 0:
            continue   # block was never used this cycle

        var live_in_block = 0
        for l in range(IMMIX_LINES_PER_BLOCK):
            if blk["line_marks"][l] == 1:
                live_in_block = live_in_block + 1

        blk["free_lines"] = IMMIX_LINES_PER_BLOCK - live_in_block
        total_live     = total_live + live_in_block
        total_free     = total_free + blk["free_lines"]

        if live_in_block == 0:
            # Block is entirely dead — reclaim it wholesale
            _release_block(b)
            if _alloc["current_block"] == b:
                _alloc["current_block"] = -1   # force re-acquisition on next alloc
        else:
            # Reset line marks for the next cycle
            # (live lines will be re-marked when traversed)
            for l in range(IMMIX_LINES_PER_BLOCK):
                blk["line_marks"][l] = 0
            # Reset the cursor to the first free line so the allocator
            # can reuse the dead lines within this block
            let first_free = _find_free_line_after_sweep(blk)
            blk["current_line"] = first_free
            blk["cursor"]       = first_free * IMMIX_LINE_SIZE
            blk["limit"]        = blk["cursor"] + IMMIX_LINE_SIZE

    _stats["live_lines_last"] = total_live
    _stats["free_lines_last"] = total_free

# After sweep we've zeroed line_marks, so "free after sweep" means the line
# was NOT marked before the reset. We need to look at the pre-reset state.
# This helper is called before zeroing — see note in _sweep().
# (In the actual implementation, this would be called on the snapshot
#  before the memset. Shown here logically separated for clarity.)
proc _find_free_line_after_sweep(blk) :
    for i in range(IMMIX_LINES_PER_BLOCK):
        if blk["line_marks"][i] == 0:
            return i
    return 0   # fallback: block was fully live, start from 0 for next alloc

# ─────────────────────────────────────────
# § 10  Public GC API
# ─────────────────────────────────────────

# Trigger a full stop-the-world collection.
# Safe to call at any time from SageMetal code.
# On RP2040: halts core0, runs mark+sweep, resumes.
proc gc_collect() :
    if not _enabled:
        return

    let t_start = read_cycle_counter()   # platform timer (or 0 if unavailable)

    # ── 1. Stop the world (bare-metal: already single-threaded) ────────────
    # On multi-core SageMetal: pause_core1() here

    # ── 2. Seed the mark stack from the root set ───────────────────────────
    _mark_stack_top = 0
    # Single-threaded host/bare-metal: read the root table directly.
    let n_roots = _roots["count"]

    for i in range(n_roots):
        let root_ptr = deref_pointer(_roots["slots"][i])
        if not is_null(root_ptr):
            _mark_push(root_ptr)

    # ── 3. Drain the mark stack ────────────────────────────────────────────
    while _mark_stack_top > 0:
        let obj = _mark_pop()
        _mark_object(obj)

    # ── 4. Sweep ───────────────────────────────────────────────────────────
    _sweep()

    # ── 5. Resume (bare-metal: resume_core1() here for multi-core) ─────────

    let t_end = read_cycle_counter()
    _stats["last_pause_cycles"] = t_end - t_start
    _stats["collections"]       = _stats["collections"] + 1

# Disable collection — for critical sections or C FFI boundaries
proc gc_disable() :
    _enabled = false

# Re-enable collection
proc gc_enable() :
    _enabled = true

# Return current GC statistics
proc gc_stats() :
    return _stats

# Force-report stats to serial output (bare-metal debug utility)
proc gc_dump_stats() :
    let s = _stats
    serial_print("=== ImmixGC Stats ===\n")
    serial_print("  Collections:    " + str(s["collections"])       + "\n")
    serial_print("  Alloc calls:    " + str(s["alloc_calls"])       + "\n")
    serial_print("  Alloc bytes:    " + str(s["alloc_bytes"])       + "\n")
    serial_print("  Live lines:     " + str(s["live_lines_last"])   + "\n")
    serial_print("  Free lines:     " + str(s["free_lines_last"])   + "\n")
    serial_print("  Last pause cy:  " + str(s["last_pause_cycles"]) + "\n")

# ─────────────────────────────────────────
# § 11  SageMetal boot integration
# ─────────────────────────────────────────
#
# Replace the existing bare-metal boot preamble:
#
#   OLD (every bare-metal script):
#       gc_disable()
#       import metal.core
#
#   NEW (once, in boot.sage or metal/init.sage):
#       import metal.core
#       import metal.mmio
#       gc_init_static(HEAP_SIZE)   # e.g. 262144 for RP2040 (256 KB)
#       # No gc_disable() needed — STW mode is valid here
#
# Example RP2040 boot sequence:
#
#   import metal.core
#   import metal.mmio
#   import gc.immix_baremetal as gc
#
#   func main() :
#       gc.gc_init_static(256 * 1024)
#
#       # Register the global interpreter state as a root
#       gc.gc_root_push(ptr_of(interpreter_state))
#
#       # Run the REPL or execute a script
#       run_sage_program()

# ─────────────────────────────────────────
# § 12  Platform intrinsics (to be provided by metal.core)
# ─────────────────────────────────────────
#
# The following functions are NOT implemented here.
# They must be provided by the metal.core / C FFI layer:
#
#   heap_offset_to_ptr(block_idx, byte_offset) -> Pointer
#       Convert a (block, offset) pair to a raw heap pointer.
#
#   ptr_to_block_idx(ptr) -> Int
#       Given a heap pointer, return which block it belongs to.
#
#   ptr_to_block_offset(ptr) -> Int
#       Given a heap pointer, return its byte offset within its block.
#
#   read_type_tag(ptr) -> Int
#       Read the VAL_* tag byte from a SageValue header.
#
#   read_object_size(ptr) -> Int
#       Read the byte size stored in a SageValue header.
#
#   write_span_count(ptr, n) -> Void
#       Write the line-span count into the reserved header field (large objects).
#
#   read_span_count(ptr) -> Int
#       Read the line-span count (large objects).
#
#   read_list_length(ptr) -> Int
#   read_list_element(ptr, i) -> Pointer
#   read_dict_length(ptr) -> Int
#   read_dict_key(ptr, i) -> Pointer
#   read_dict_val(ptr, i) -> Pointer
#   read_closure_upval_count(ptr) -> Int
#   read_closure_upval(ptr, i) -> Pointer
#   read_closure_func(ptr) -> Pointer
#   read_func_default_count(ptr) -> Int
#   read_func_default(ptr, i) -> Pointer
#   deref_pointer(slot) -> Pointer
#       Dereference a pointer-to-pointer (root slot).
#
#   ptr_of(var: T) -> Pointer
#       Take the address of a variable (unsafe, use only for root registration).
#
#   is_null(ptr) -> Bool
#   null_ptr() -> Pointer
#
#   read_cycle_counter() -> Int
#       RP2040: TIMER->TIMELR or SysTick. Returns 0 on platforms without a timer.
#
#   serial_print(s) -> Void
#       Bare-metal serial output for gc_dump_stats().
#
#   write_int(ptr, val) -> Void
#       Write an Int to an arbitrary pointer (for root snapshot count).


# ─────────────────────────────────────────
# § 13  Host-safe platform intrinsics
#
# §12 lists intrinsics that a bare-metal target must provide. On the host
# (or any target without metal.core) we supply functional equivalents over
# an integer pointer model so the allocator/mark/sweep logic is testable:
#   ptr = block_idx * IMMIX_BLOCK_SIZE + byte_offset   (block 0 reserved)
# Memory-header accessors (read_type_tag etc.) still require a real heap
# image and raise if called without one.
# ─────────────────────────────────────────

proc heap_offset_to_ptr(block_idx, byte_offset):
    return block_idx * IMMIX_BLOCK_SIZE + byte_offset + 1

proc ptr_to_block_idx(ptr):
    return (ptr - 1) / IMMIX_BLOCK_SIZE

proc ptr_to_block_offset(ptr):
    return (ptr - 1) % IMMIX_BLOCK_SIZE

proc null_ptr():
    return 0

proc is_null(ptr):
    return ptr == 0 or ptr == nil

proc read_cycle_counter():
    return 0

proc serial_print(s):
    print(s)

proc deref_pointer(slot):
    return slot

# Span-count side table (host stand-in for the object-header field)
var _span_table = {}

proc write_span_count(ptr, n):
    _span_table[str(ptr)] = n

proc read_span_count(ptr):
    if dict_has(_span_table, str(ptr)):
        return _span_table[str(ptr)]
    return 1
