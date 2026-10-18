// Permafrost Overhaul, native side (dlls\main.dll). One UE4SS C++ mod that
// holds everything Lua cannot do. Each part is driven by its Lua module
// through a small text file in dlls\, so turning a module off in config.lua
// turns its native part off too:
//   craft from storage  <- craftfromstorage.lua  (state.txt)
//   spawn blocker       <- spawndistance.lua     (spawnblock.txt)
//   headshot damage     <- betterguns.lua        (combat.txt)
//   gunshot hall reverb <- betterguns.lua        (reverb.txt)
//   toolbelt knife      <- toolbelt.lua          (toolbelt.txt)
//   survival rates      <- survivaltweaks.lua    (survival.txt)
//   crash report        <- Modules.diagnostics   (config.lua)
// Log: dlls\main.log.
//
// UE4SS.dll is not linked; the mod object mirrors UE4SS v3.0.1
// CppUserModBase (0xD0 bytes, 16 virtual slots). Build: src\build.bat.
//
// Craft from storage: crafting and repairs use items in nearby storage
// chests. No game addresses are hardcoded; everything comes from reflection:
//  - Lua writes dlls\state.txt: the player's EquipmentComponent, inventory
//    components of storage chests in range, and UFunction addresses.
//  - "Crafting in progress" = a crafting/repair/crafting-widget UFunction is on
//    the stack. Each of those UFunctions gets its Func pointer (UFunction+0xD8)
//    swapped for a tiny wrapper that counts depth. Data swap, no code patching.
//  - The player's EquipmentComponent vtable gets four slots replaced:
//    GetItemQuantity, GetItemsList, RemoveItemAmount, CheckForItem (building). Slot numbers are read
//    from the matching UInventoryComponent exec thunks (call [rax+disp32]).
//    While crafting is in progress and `this` is the player's equipment, the
//    hooks add chest contents (quantity/list) or take the shortfall from chests
//    (remove). Chests are plain UInventoryComponents with their own vtable, so
//    calling them never re-enters the hooks.
//  - Every chest pointer is checked against GUObjectArray (index, serial
//    object pointer, Garbage/Unreachable flags) before use. The array address
//    is read from UE4SS.log ("Found GUObjectArray").

#include <windows.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cmath>
#include <cstdarg>
#include <cstring>
#include <string>
#include <unordered_set>
#include <utility>
#include <vector>

namespace {

constexpr wchar_t kTag[] = L"[Overhaul] ";

// ---- logging -----------------------------------------------------------------

std::wstring g_dir;  // ...\Mods\CraftFromStorage\dlls\ (trailing backslash)
std::wstring g_log;
CRITICAL_SECTION g_log_lock;

void logf(const wchar_t* fmt, ...) {
    if (g_log.empty()) return;
    wchar_t msg[1024];
    va_list args;
    va_start(args, fmt);
    vswprintf_s(msg, fmt, args);
    va_end(args);
    SYSTEMTIME t;
    GetLocalTime(&t);
    wchar_t line[1200];
    swprintf_s(line, L"[%02u:%02u:%02u.%03u] %s%s\r\n", t.wHour, t.wMinute, t.wSecond, t.wMilliseconds, kTag, msg);
    char utf8[2400];
    int n = WideCharToMultiByte(CP_UTF8, 0, line, -1, utf8, sizeof(utf8), nullptr, nullptr);
    if (n <= 1) return;
    EnterCriticalSection(&g_log_lock);
    HANDLE f = CreateFileW(g_log.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ, nullptr, OPEN_ALWAYS,
                           FILE_ATTRIBUTE_NORMAL, nullptr);
    if (f != INVALID_HANDLE_VALUE) {
        DWORD written = 0;
        WriteFile(f, utf8, static_cast<DWORD>(n - 1), &written, nullptr);
        CloseHandle(f);
    }
    LeaveCriticalSection(&g_log_lock);
}

// ---- engine layout (UE 5.4, matches UE4SS.log member offsets) -----------------

constexpr size_t kObjFlags = 0x08;          // UObjectBase::ObjectFlags
constexpr size_t kObjIndex = 0x0C;          // UObjectBase::InternalIndex
constexpr size_t kUFunctionFunc = 0xD8;     // UFunction::Func
constexpr size_t kObjObjects = 0x10;        // FUObjectArray::ObjObjects
constexpr size_t kItemSize = 0x18;          // FUObjectItem
constexpr size_t kItemFlags = 0x08;         // FUObjectItem::Flags
constexpr int kChunk = 64 * 1024;
constexpr uint32_t kBadInternal = 0x10200000;  // Unreachable | Garbage
constexpr uint32_t kBadObjFlags = 0x18030;     // CDO | Archetype | BeginDestroyed | FinishDestroyed
constexpr size_t kAmountOffset = 0x28;      // FItemAmount::Amount
constexpr size_t kItemAmountSize = 0x30;

uint8_t* g_objarray = nullptr;  // FUObjectArray*

bool readable(const void* p, size_t n) {
    MEMORY_BASIC_INFORMATION mbi{};
    if (!p || !VirtualQuery(p, &mbi, sizeof(mbi))) return false;
    if (mbi.State != MEM_COMMIT || (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD))) return false;
    auto end = static_cast<const uint8_t*>(mbi.BaseAddress) + mbi.RegionSize;
    return static_cast<const uint8_t*>(p) + n <= end;
}

// True if `obj` is still the live object registered at `index`.
bool alive(void* obj, int32_t index) {
    if (!obj || index < 0 || !g_objarray) return false;
    uint8_t* arr = g_objarray + kObjObjects;
    auto chunks = *reinterpret_cast<uint8_t***>(arr + 0x00);
    int32_t num = *reinterpret_cast<int32_t*>(arr + 0x14);
    int32_t num_chunks = *reinterpret_cast<int32_t*>(arr + 0x1C);
    if (!chunks || index >= num || index / kChunk >= num_chunks) return false;
    uint8_t* chunk = chunks[index / kChunk];
    if (!chunk) return false;
    uint8_t* item = chunk + static_cast<size_t>(index % kChunk) * kItemSize;
    if (*reinterpret_cast<void**>(item) != obj) return false;
    if (*reinterpret_cast<uint32_t*>(item + kItemFlags) & kBadInternal) return false;
    if (*reinterpret_cast<uint32_t*>(static_cast<uint8_t*>(obj) + kObjFlags) & kBadObjFlags) return false;
    return true;
}

int32_t index_of(void* obj) {
    if (!readable(obj, kObjIndex + 4)) return -1;
    return *reinterpret_cast<int32_t*>(static_cast<uint8_t*>(obj) + kObjIndex);
}

// ---- shared state from Lua ----------------------------------------------------

struct Ref {
    void* obj = nullptr;
    int32_t index = -1;
};

struct Snapshot {
    Ref equip;
    Ref inv2;  // building component's PlayerInventory when it is a different object
    std::vector<Ref> chests;
    bool enabled = true;
    bool building = false;  // Lua: build mode / construction active (held 3 s after)
};

// Ring of snapshots; hooks read the current one without locking. A slot is
// reused only after 8 more updates (2 s), far longer than any hook call.
std::array<Snapshot, 8> g_snaps;
std::atomic<int> g_snap_index{-1};

const Snapshot* current() {
    int i = g_snap_index.load(std::memory_order_acquire);
    return i < 0 ? nullptr : &g_snaps[i];
}

// ---- crafting-in-progress depth (UFunction wrappers) --------------------------

using NativeFn = void (*)(void* context, void* stack, void* result);
constexpr int kPool = 768;
NativeFn g_orig[kPool];
uint8_t g_kind[kPool];  // 1 = crafting/repair component, 2 = crafting widget
int g_pool_used = 0;
std::unordered_set<uintptr_t> g_wrapped;  // UFunction addresses (update thread only)

thread_local int t_craft = 0;
thread_local int t_ui = 0;

template <int I>
void wrapper(void* context, void* stack, void* result) {
    const bool craft = g_kind[I] == 1;
    if (craft) ++t_craft; else ++t_ui;
    g_orig[I](context, stack, result);
    if (craft) --t_craft; else --t_ui;
}

template <int... I>
constexpr std::array<NativeFn, sizeof...(I)> make_wrappers(std::integer_sequence<int, I...>) {
    return {&wrapper<I>...};
}
const auto g_wrappers = make_wrappers(std::make_integer_sequence<int, kPool>{});

void wrap_ufunction(uintptr_t ufunc, uint8_t kind) {
    if (!ufunc || g_wrapped.count(ufunc)) return;
    auto slot = reinterpret_cast<NativeFn*>(ufunc + kUFunctionFunc);
    if (!readable(slot, sizeof(void*))) return;
    NativeFn fn = *slot;
    if (!fn) return;
    for (int i = 0; i < g_pool_used; ++i) {
        if (fn == g_wrappers[i]) { g_wrapped.insert(ufunc); return; }
    }
    if (g_pool_used >= kPool) return;
    int i = g_pool_used++;
    g_orig[i] = fn;
    g_kind[i] = kind;
    *slot = g_wrappers[i];  // aligned 8-byte store
    g_wrapped.insert(ufunc);
}

// ---- inventory vtable hooks ---------------------------------------------------
// Up to 4 vtables can be patched: the player's EquipmentComponent and, if the
// building component uses a different inventory object (PlayerInventory), that
// object's class too. A plain UInventoryComponent vtable is shared with the
// chests, so chests are always called through the saved ORIGINAL functions of
// their vtable, never through the patched slots.

using QtyFn = int (*)(void* self, const void* soft_ptr);
using ListFn = void (*)(void* self, void* map);
using RemoveFn = int (*)(void* self, const void* item_amount, bool a, bool b);
using CheckFn = bool (*)(void* self, const void* item_amount);

int g_slot_qty = -1, g_slot_list = -1, g_slot_remove = -1, g_slot_check = -1;  // byte offsets

struct Patched {
    void** vtable = nullptr;
    QtyFn qty = nullptr;
    ListFn list = nullptr;
    RemoveFn remove = nullptr;
    CheckFn check = nullptr;
};
std::array<Patched, 4> g_patched;
std::atomic<int> g_patched_count{0};
std::atomic<int> g_stat_qty{0}, g_stat_list{0}, g_stat_remove{0}, g_stat_check{0};

const Patched* find_patched(void** vtable) {
    int n = g_patched_count.load(std::memory_order_acquire);
    for (int i = 0; i < n; ++i) {
        if (g_patched[i].vtable == vtable) return &g_patched[i];
    }
    return nullptr;
}

void** vtable_of(const void* obj) { return *reinterpret_cast<void** const*>(obj); }

// Original (unhooked) implementations for any object.
QtyFn orig_qty(const void* obj) {
    auto vt = vtable_of(obj);
    if (auto p = find_patched(vt)) return p->qty;
    return reinterpret_cast<QtyFn>(vt[g_slot_qty / 8]);
}
ListFn orig_list(const void* obj) {
    auto vt = vtable_of(obj);
    if (auto p = find_patched(vt)) return p->list;
    return reinterpret_cast<ListFn>(vt[g_slot_list / 8]);
}
RemoveFn orig_remove(const void* obj) {
    auto vt = vtable_of(obj);
    if (auto p = find_patched(vt)) return p->remove;
    return reinterpret_cast<RemoveFn>(vt[g_slot_remove / 8]);
}
CheckFn orig_check(const void* obj) {
    auto vt = vtable_of(obj);
    if (auto p = find_patched(vt)) return p->check;
    return reinterpret_cast<CheckFn>(vt[g_slot_check / 8]);
}

// Removal needs a crafting/repair/building UFunction on the stack, or active
// building (its costs are paid from Blueprint). Counting also accepts the
// crafting widgets. Only the player's own inventory objects qualify.
const Snapshot* gate(void* self, bool removal) {
    const Snapshot* s = current();
    if (!s || !s->enabled || s->chests.empty()) return nullptr;
    if (self != s->equip.obj && self != s->inv2.obj) return nullptr;
    bool active = t_craft > 0 || s->building || (!removal && t_ui > 0);
    return active ? s : nullptr;
}

bool is_player_inv(const Snapshot* s, void* obj) { return obj == s->equip.obj || obj == s->inv2.obj; }

// Only the outermost hook call adds chests. EquipmentComponent implements its
// totals by calling its sub-inventories, which may themselves be hooked.
thread_local int t_hook = 0;
struct HookScope {
    HookScope() { ++t_hook; }
    ~HookScope() { --t_hook; }
};

int hook_qty(void* self, const void* soft_ptr) {
    const bool outer = t_hook == 0;
    HookScope scope;
    int total = orig_qty(self)(self, soft_ptr);
    if (const Snapshot* s = outer ? gate(self, false) : nullptr) {
        for (const Ref& c : s->chests) {
            if (!is_player_inv(s, c.obj) && alive(c.obj, c.index)) total += orig_qty(c.obj)(c.obj, soft_ptr);
        }
        g_stat_qty.fetch_add(1, std::memory_order_relaxed);
    }
    return total;
}

void hook_list(void* self, void* map) {
    const bool outer = t_hook == 0;
    HookScope scope;
    orig_list(self)(self, map);
    if (const Snapshot* s = outer ? gate(self, false) : nullptr) {
        // UInventoryComponent::GetItemsList adds into existing map entries,
        // so each chest merges straight into the player's list.
        for (const Ref& c : s->chests) {
            if (!is_player_inv(s, c.obj) && alive(c.obj, c.index)) orig_list(c.obj)(c.obj, map);
        }
        g_stat_list.fetch_add(1, std::memory_order_relaxed);
    }
}

int hook_remove(void* self, const void* item_amount, bool a, bool b) {
    const bool outer = t_hook == 0;
    HookScope scope;
    int removed = orig_remove(self)(self, item_amount, a, b);
    const Snapshot* s = outer ? gate(self, true) : nullptr;
    if (!s) return removed;
    int wanted = *reinterpret_cast<const int32_t*>(static_cast<const uint8_t*>(item_amount) + kAmountOffset);
    int left = wanted - removed;
    if (left <= 0) return removed;
    // Shallow copy: the callee takes it by const&, so sharing the SubPath
    // FString buffer is fine as long as this copy is never destroyed.
    alignas(16) uint8_t copy[kItemAmountSize];
    memcpy(copy, item_amount, kItemAmountSize);
    for (const Ref& c : s->chests) {
        if (left <= 0) break;
        if (is_player_inv(s, c.obj) || !alive(c.obj, c.index)) continue;
        *reinterpret_cast<int32_t*>(copy + kAmountOffset) = left;
        int got = orig_remove(c.obj)(c.obj, copy, a, b);
        if (got > 0) { left -= got; removed += got; }
    }
    g_stat_remove.fetch_add(1, std::memory_order_relaxed);
    if (left > 0) logf(L"WARN: wanted %d, %d could not be found in player or chests", wanted, left);
    return removed;
}

// CheckForItem(FItemAmount): building costs use this. FItemAmount starts with
// the TSoftObjectPtr, so the same pointer works for GetItemQuantity.
bool hook_check(void* self, const void* item_amount) {
    const bool outer = t_hook == 0;
    HookScope scope;
    if (orig_check(self)(self, item_amount)) return true;
    const Snapshot* s = outer ? gate(self, false) : nullptr;
    if (!s) return false;
    int wanted = *reinterpret_cast<const int32_t*>(static_cast<const uint8_t*>(item_amount) + kAmountOffset);
    int total = orig_qty(self)(self, item_amount);
    for (const Ref& c : s->chests) {
        if (total >= wanted) break;
        if (!is_player_inv(s, c.obj) && alive(c.obj, c.index)) total += orig_qty(c.obj)(c.obj, item_amount);
    }
    g_stat_check.fetch_add(1, std::memory_order_relaxed);
    return total >= wanted;
}

// Finds the vtable byte offset used by an exec thunk: first `call [reg+disp32]`.
int slot_from_thunk(uintptr_t ufunc) {
    if (!ufunc || !readable(reinterpret_cast<void*>(ufunc + kUFunctionFunc), 8)) return -1;
    auto code = *reinterpret_cast<const uint8_t**>(ufunc + kUFunctionFunc);
    for (int i = 0; i < g_pool_used; ++i) {
        if (reinterpret_cast<const void*>(g_wrappers[i]) == code) { code = reinterpret_cast<const uint8_t*>(g_orig[i]); break; }
    }
    if (!readable(code, 0x200)) return -1;
    for (int i = 0; i < 0x200 - 6; ++i) {
        if (code[i] == 0xFF) {
            uint8_t modrm = code[i + 1];
            if ((modrm & 0xF8) == 0x90 && (modrm & 7) != 4) {  // mod=10, reg=/2, rm!=SIB
                int32_t disp;
                memcpy(&disp, code + i + 2, 4);
                if (disp > 0 && disp < 0x2000 && disp % 8 == 0) return disp;
            }
        }
        // No early stop on 0xC3: that byte also occurs inside instructions.
    }
    return -1;
}

bool find_slots(uintptr_t fn_qty, uintptr_t fn_list, uintptr_t fn_remove, uintptr_t fn_check) {
    if (g_slot_qty >= 0) return true;
    int q = slot_from_thunk(fn_qty), l = slot_from_thunk(fn_list), r = slot_from_thunk(fn_remove),
        c = slot_from_thunk(fn_check);
    if (q < 0 || l < 0 || r < 0 || c < 0) {
        logf(L"FAIL: vtable slots not found (qty %d, list %d, remove %d, check %d). Mod inactive.", q, l, r, c);
        return false;
    }
    g_slot_qty = q; g_slot_list = l; g_slot_remove = r; g_slot_check = c;
    return true;
}

// Patches the 4 slots in `obj`'s vtable once. Originals are saved before the
// table entry becomes visible to hooks.
bool patch_object(void* obj, const wchar_t* what) {
    if (!obj || g_slot_qty < 0) return false;
    auto vtable = vtable_of(obj);
    if (find_patched(vtable)) return true;
    int n = g_patched_count.load();
    if (n >= static_cast<int>(g_patched.size())) return false;
    void** slots[4] = {&vtable[g_slot_qty / 8], &vtable[g_slot_list / 8], &vtable[g_slot_remove / 8],
                       &vtable[g_slot_check / 8]};
    for (auto s : slots) {
        if (!readable(s, 8)) { logf(L"FAIL: vtable not readable (%s)", what); return false; }
    }
    Patched& p = g_patched[n];
    p.vtable = vtable;
    p.qty = reinterpret_cast<QtyFn>(*slots[0]);
    p.list = reinterpret_cast<ListFn>(*slots[1]);
    p.remove = reinterpret_cast<RemoveFn>(*slots[2]);
    p.check = reinterpret_cast<CheckFn>(*slots[3]);
    g_patched_count.store(n + 1, std::memory_order_release);
    void* hooks[4] = {reinterpret_cast<void*>(&hook_qty), reinterpret_cast<void*>(&hook_list),
                      reinterpret_cast<void*>(&hook_remove), reinterpret_cast<void*>(&hook_check)};
    for (int i = 0; i < 4; ++i) {
        DWORD old = 0;
        if (!VirtualProtect(slots[i], 8, PAGE_READWRITE, &old)) { logf(L"FAIL: VirtualProtect"); return false; }
        *slots[i] = hooks[i];
        VirtualProtect(slots[i], 8, old, &old);
    }
    logf(L"%s vtable %p patched: GetItemQuantity +0x%X, GetItemsList +0x%X, RemoveItemAmount +0x%X, "
         L"CheckForItem +0x%X", what, vtable, g_slot_qty, g_slot_list, g_slot_remove, g_slot_check);
    return true;
}

// ---- GUObjectArray from UE4SS.log ------------------------------------------------

bool find_objarray() {
    if (g_objarray) return true;
    std::wstring path = g_dir + L"..\\..\\..\\UE4SS.log";
    HANDLE f = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
                           FILE_ATTRIBUTE_NORMAL, nullptr);
    if (f == INVALID_HANDLE_VALUE) return false;
    std::string text(64 * 1024, '\0');
    DWORD got = 0;
    ReadFile(f, text.data(), static_cast<DWORD>(text.size()), &got, nullptr);
    CloseHandle(f);
    text.resize(got);
    size_t at = text.find("Found GUObjectArray: 0x");
    if (at == std::string::npos) return false;
    uintptr_t addr = std::strtoull(text.c_str() + at + 23, nullptr, 16);
    if (!readable(reinterpret_cast<void*>(addr), 0x30)) return false;
    g_objarray = reinterpret_cast<uint8_t*>(addr);
    logf(L"GUObjectArray at %p", g_objarray);
    return true;
}

// ---- state file ---------------------------------------------------------------

FILETIME g_state_time{};
uintptr_t g_fn_qty = 0, g_fn_list = 0, g_fn_remove = 0, g_fn_check = 0;
bool g_logged_ready = false;
std::atomic<bool> g_crash_armed{false};  // crash report: armed once in the world

void read_state() {
    std::wstring path = g_dir + L"state.txt";
    WIN32_FILE_ATTRIBUTE_DATA attr{};
    if (!GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &attr)) return;
    if (CompareFileTime(&attr.ftLastWriteTime, &g_state_time) == 0) return;
    HANDLE f = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                           OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (f == INVALID_HANDLE_VALUE) return;
    std::string text(256 * 1024, '\0');
    DWORD got = 0;
    ReadFile(f, text.data(), static_cast<DWORD>(text.size()), &got, nullptr);
    CloseHandle(f);
    text.resize(got);
    text.erase(std::remove(text.begin(), text.end(), '\r'), text.end());  // tolerate CRLF
    if (text.find("\nend\n") == std::string::npos) return;  // partial write; try next tick
    g_state_time = attr.ftLastWriteTime;

    int next = (g_snap_index.load() + 1) % static_cast<int>(g_snaps.size());
    Snapshot& s = g_snaps[next];
    s = Snapshot{};
    size_t pos = 0;
    while (pos < text.size()) {
        size_t eol = text.find('\n', pos);
        if (eol == std::string::npos) eol = text.size();
        std::string line = text.substr(pos, eol - pos);
        pos = eol + 1;
        size_t eq = line.find('=');
        if (eq == std::string::npos) continue;
        std::string key = line.substr(0, eq);
        uintptr_t v = std::strtoull(line.c_str() + eq + 1, nullptr, 16);
        if (key == "enabled") s.enabled = v != 0;
        else if (key == "building") s.building = v != 0;
        else if (key == "fn_check") g_fn_check = v;
        else if (key == "equip") s.equip = {reinterpret_cast<void*>(v), index_of(reinterpret_cast<void*>(v))};
        else if (key == "inv2") s.inv2 = {reinterpret_cast<void*>(v), index_of(reinterpret_cast<void*>(v))};
        else if (key == "chest") s.chests.push_back({reinterpret_cast<void*>(v), index_of(reinterpret_cast<void*>(v))});
        else if (key == "fn_qty") g_fn_qty = v;
        else if (key == "fn_list") g_fn_list = v;
        else if (key == "fn_remove") g_fn_remove = v;
        else if (key == "craft") wrap_ufunction(v, 1);
        else if (key == "ui") wrap_ufunction(v, 2);
    }
    if (s.equip.obj && !alive(s.equip.obj, s.equip.index)) s.equip = {};
    if (s.inv2.obj && !alive(s.inv2.obj, s.inv2.index)) s.inv2 = {};
    g_snap_index.store(next, std::memory_order_release);

    if (s.equip.obj && g_fn_qty && g_fn_list && g_fn_remove && g_fn_check &&
        find_slots(g_fn_qty, g_fn_list, g_fn_remove, g_fn_check)) {
        patch_object(s.equip.obj, L"equipment");
        if (s.inv2.obj) patch_object(s.inv2.obj, L"building inventory");
    }
    if (g_patched_count.load() > 0 && !g_logged_ready) {
        g_logged_ready = true;
        g_crash_armed.store(true);
        logf(L"ready: %d UFunctions wrapped, %zu chest inventories in range", g_pool_used, s.chests.size());
    }
}

ULONGLONG g_next_poll = 0;
ULONGLONG g_next_stats = 0;

void read_spawnblock();  // spawn blocker, below
void read_combat();      // headshots, below
void read_toolbelt();    // toolbelt, below
void read_reverb();      // hall reverb, below
void write_animal_refused();  // animal spawn blocker, below
void read_travel();      // fast travel food cost, below
void install_reverb();
void read_survival();    // survival rates, below

void tick() {
    ULONGLONG now = GetTickCount64();
    if (now < g_next_poll) return;
    g_next_poll = now + 250;
    if (!find_objarray()) return;  // chest validation needs it; stay inactive until found
    read_state();
    read_spawnblock();
    read_combat();
    read_toolbelt();
    install_reverb();
    read_reverb();
    write_animal_refused();
    read_travel();
    read_survival();
    if (g_patched_count.load() > 0 && now >= g_next_stats) {
        g_next_stats = now + 60000;
        int q = g_stat_qty.exchange(0), l = g_stat_list.exchange(0), r = g_stat_remove.exchange(0),
            c = g_stat_check.exchange(0);
        if (q || l || r || c)
            logf(L"last minute: %d quantity, %d list, %d check, %d removal calls used chests", q, l, c, r);
    }
}

// Which of our native hooks is running on this thread (for crash reports).
thread_local int t_in_spawn = 0, t_in_damage = 0, t_in_tool = 0;
struct InHook {
    int& r;
    explicit InHook(int& x) : r(x) { ++r; }
    ~InHook() { --r; }
};

// ---- spawn blocker ----------------------------------------------------------------
// Every fresh spawn of every ASpawner_BaseType subclass (SpawnInBunch,
// CircularSpawnRoute) first asks the non-virtual
// ASpawner_BaseType::CheckIfSpawnProcessIsValid(this). We detour it and answer
// "no" while the player is within block_cm of the spawner, so the game skips
// the spawn on its own. NPCs restored from the save use another path.
// Security-sensitive: patches 15 bytes of game code in memory (found by byte
// signature, prologue verified, fails closed); nothing on disk changes.
// Player position and a calibration sample come from Lua (SpawnDistance
// module) through dlls\spawnblock.txt; the root component and location offsets
// are found by matching that sample, so no game offsets are hardcoded.
using SpawnCheckFn = bool (*)(void* spawner);
SpawnCheckFn g_spawn_tramp = nullptr;
std::atomic<long long> g_block_cm{0};
std::atomic<long long> g_animal_cm{0};  // animal spawn point limit (animal spawn blocker below)
std::atomic<long long> g_px{0}, g_py{0}, g_pz{0};
std::atomic<bool> g_player_known{false};
std::atomic<int> g_root_off{-1}, g_loc_off{-1};
std::atomic<int> g_blocked{0}, g_allowed{0};
FILETIME g_block_time{};
// Story spawners (quest NPCs like Finn) Lua says to leave alone: allow= line.
SRWLOCK g_exempt_lock = SRWLOCK_INIT;
std::unordered_set<uintptr_t> g_exempt;
std::atomic<int> g_exempt_used{0};

bool spawn_exempt(void* sp) {
    AcquireSRWLockShared(&g_exempt_lock);
    const bool hit = g_exempt.count(reinterpret_cast<uintptr_t>(sp)) != 0;
    ReleaseSRWLockShared(&g_exempt_lock);
    return hit;
}

bool spawn_check_detour(void* sp) {
    InHook in_hook(t_in_spawn);
    const long long cm = g_block_cm.load(std::memory_order_relaxed);
    const int ro = g_root_off.load(std::memory_order_acquire), lo = g_loc_off.load(std::memory_order_acquire);
    if (sp && cm > 0 && spawn_exempt(sp)) {
        int n = g_exempt_used.fetch_add(1) + 1;
        if (n <= 10) logf(L"spawn not blocked #%d: story spawner", n);
        return g_spawn_tramp(sp);
    }
    if (sp && cm > 0 && ro >= 0 && lo >= 0 && g_player_known.load(std::memory_order_acquire)) {
        void* root = *reinterpret_cast<void* const*>(static_cast<const uint8_t*>(sp) + ro);
        if (root) {
            const double* p = reinterpret_cast<const double*>(static_cast<const uint8_t*>(root) + lo);
            const double dx = p[0] - static_cast<double>(g_px.load()), dy = p[1] - static_cast<double>(g_py.load()),
                         dz = p[2] - static_cast<double>(g_pz.load());
            const double d2 = dx * dx + dy * dy + dz * dz;
            if (d2 < static_cast<double>(cm) * static_cast<double>(cm)) {
                int n = g_blocked.fetch_add(1) + 1;
                if (n <= 25 || n % 100 == 0)
                    logf(L"spawn blocked #%d: spawner %.0f m from you (limit %lld m)", n, sqrt(d2) / 100.0, cm / 100);
                return false;
            }
        }
    }
    const bool ok = g_spawn_tramp(sp);
    if (ok) {
        int n = g_allowed.fetch_add(1) + 1;
        if (n <= 10) logf(L"spawn allowed #%d (spawner beyond the limit)", n);
    }
    return ok;
}

// Signature of the function start (prologue + first private-flag checks).
bool match_spawn_check(const uint8_t* p) {
    static const int16_t sig[] = {
        0x48, 0x89, 0x5C, 0x24, 0x08, 0x48, 0x89, 0x74, 0x24, 0x10, 0x57, 0x48, 0x83, 0xEC, 0x20,
        0x80, 0xB9, -1, -1, 0x00, 0x00, 0x00, 0x48, 0x8B, 0xF9, 0x0F, 0x85, -1, -1, -1, -1,
        0x80, 0xB9, -1, -1, 0x00, 0x00, 0x00, 0x0F, 0x85, -1, -1, -1, -1,
        0x80, 0xB9, -1, -1, 0x00, 0x00, 0x00, 0x0F, 0x85, -1, -1, -1, -1,
        0x80, 0xB9, -1, -1, 0x00, 0x00, 0x01};
    for (size_t i = 0; i < sizeof(sig) / sizeof(sig[0]); ++i) {
        if (sig[i] >= 0 && p[i] != static_cast<uint8_t>(sig[i])) return false;
    }
    return true;
}

void install_spawn_blocker() {
    auto base = reinterpret_cast<uint8_t*>(GetModuleHandleW(nullptr));
    auto dos = reinterpret_cast<IMAGE_DOS_HEADER*>(base);
    auto nt = reinterpret_cast<IMAGE_NT_HEADERS64*>(base + dos->e_lfanew);
    auto sec = IMAGE_FIRST_SECTION(nt);
    uint8_t* found = nullptr;
    int matches = 0;
    for (int s = 0; s < nt->FileHeader.NumberOfSections; ++s, ++sec) {
        if (!(sec->Characteristics & IMAGE_SCN_MEM_EXECUTE)) continue;
        uint8_t* p = base + sec->VirtualAddress;
        size_t n = sec->Misc.VirtualSize;
        for (size_t i = 0; i + 64 < n; ++i) {
            if (p[i] == 0x48 && p[i + 15] == 0x80 && match_spawn_check(p + i)) {
                found = p + i;
                ++matches;
            }
        }
    }
    if (matches != 1) {
        logf(L"spawn blocker OFF: CheckIfSpawnProcessIsValid signature found %d times (need 1)", matches);
        return;
    }
    // Trampoline: the 15 prologue bytes (no RIP-relative operands), then jmp back.
    auto tramp = static_cast<uint8_t*>(VirtualAlloc(nullptr, 64, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE));
    if (!tramp) { logf(L"spawn blocker OFF: VirtualAlloc failed"); return; }
    memcpy(tramp, found, 15);
    const uint8_t jmp_abs[6] = {0xFF, 0x25, 0x00, 0x00, 0x00, 0x00};  // jmp [rip+0]
    memcpy(tramp + 15, jmp_abs, 6);
    uint64_t back = reinterpret_cast<uint64_t>(found + 15);
    memcpy(tramp + 21, &back, 8);
    g_spawn_tramp = reinterpret_cast<SpawnCheckFn>(tramp);

    uint8_t patch[15];
    memcpy(patch, jmp_abs, 6);
    uint64_t to = reinterpret_cast<uint64_t>(&spawn_check_detour);
    memcpy(patch + 6, &to, 8);
    patch[14] = 0x90;
    DWORD old = 0;
    if (!VirtualProtect(found, 15, PAGE_EXECUTE_READWRITE, &old)) { logf(L"spawn blocker OFF: VirtualProtect failed"); return; }
    memcpy(found, patch, 15);
    VirtualProtect(found, 15, old, &old);
    FlushInstructionCache(GetCurrentProcess(), found, 15);
    logf(L"spawn blocker hooked CheckIfSpawnProcessIsValid at exe+0x%llX", static_cast<unsigned long long>(found - base));
}

// Finds where actors keep their RootComponent pointer and where a scene
// component keeps its world location, from one spawner Lua described.
void calibrate(uintptr_t actor, uintptr_t root, double x, double y, double z) {
    if (g_root_off.load() >= 0 && g_loc_off.load() >= 0) return;
    void* a = reinterpret_cast<void*>(actor);
    void* r = reinterpret_cast<void*>(root);
    if (!alive(a, index_of(a)) || !alive(r, index_of(r))) return;
    if (!readable(a, 0x800) || !readable(r, 0x800)) return;
    int ro = -1;
    for (int off = 0x28; off < 0x800; off += 8) {
        if (*reinterpret_cast<uintptr_t*>(actor + off) == root) { ro = off; break; }
    }
    // Several copies of the location can exist (relative + world). Prefer
    // the one preceded by a unit quaternion: that is the world transform.
    int lo = -1, lo_any = -1;
    for (int off = 0x28; off + 24 <= 0x800; off += 8) {
        const double* d = reinterpret_cast<const double*>(root + off);
        if (d[0] == x && d[1] == y && d[2] == z) {
            if (lo_any < 0) lo_any = off;
            if (off >= 0x20) {
                const double* q = d - 4;
                double len = q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3];
                if (len > 0.999 && len < 1.001) { lo = off; break; }
            }
        }
    }
    if (lo < 0) lo = lo_any;
    if (ro < 0 || lo < 0) {
        logf(L"spawn blocker: calibration failed (root offset %d, location offset %d); blocker idle", ro, lo);
        return;
    }
    g_root_off.store(ro, std::memory_order_release);
    g_loc_off.store(lo, std::memory_order_release);
    logf(L"spawn blocker calibrated: RootComponent at actor+0x%X, world location at component+0x%X", ro, lo);
}

void read_spawnblock() {
    std::wstring path = g_dir + L"spawnblock.txt";
    WIN32_FILE_ATTRIBUTE_DATA attr{};
    if (!GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &attr)) return;
    if (CompareFileTime(&attr.ftLastWriteTime, &g_block_time) == 0) return;
    HANDLE f = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                           OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (f == INVALID_HANDLE_VALUE) return;
    static char buf[8192];  // allow= holds up to 200 addresses
    DWORD got = 0;
    ReadFile(f, buf, sizeof(buf) - 1, &got, nullptr);
    CloseHandle(f);
    std::string text(buf, got);
    std::unordered_set<uintptr_t> exempt;
    if (text.find("\nend\n") == std::string::npos) return;
    g_block_time = attr.ftLastWriteTime;
    size_t pos = 0;
    while (pos < text.size()) {
        size_t eol = text.find('\n', pos);
        if (eol == std::string::npos) eol = text.size();
        std::string line = text.substr(pos, eol - pos);
        pos = eol + 1;
        if (line.rfind("block=", 0) == 0) {
            g_block_cm.store(std::strtoll(line.c_str() + 6, nullptr, 10));
        } else if (line.rfind("animal=", 0) == 0) {
            g_animal_cm.store(std::strtoll(line.c_str() + 7, nullptr, 10));
        } else if (line.rfind("player=", 0) == 0) {
            long long x = 0, y = 0, z = 0;
            if (sscanf(line.c_str() + 7, "%lld,%lld,%lld", &x, &y, &z) == 3) {
                g_px.store(x); g_py.store(y); g_pz.store(z);
                g_player_known.store(true, std::memory_order_release);
            }
        } else if (line.rfind("cal=", 0) == 0) {
            unsigned long long a = 0, r = 0;
            double x = 0, y = 0, z = 0;
            if (sscanf(line.c_str() + 4, "%llX,%llX,%lf,%lf,%lf", &a, &r, &x, &y, &z) == 5) calibrate(a, r, x, y, z);
        } else if (line.rfind("allow=", 0) == 0) {
            const char* s = line.c_str() + 6;
            while (*s) {
                char* end = nullptr;
                unsigned long long a = std::strtoull(s, &end, 16);
                if (end == s) break;
                if (a) exempt.insert(static_cast<uintptr_t>(a));
                s = (*end == ',') ? end + 1 : end;
            }
        }
    }
    const size_t before = g_exempt.size();  // only this thread writes the set
    AcquireSRWLockExclusive(&g_exempt_lock);
    g_exempt.swap(exempt);
    ReleaseSRWLockExclusive(&g_exempt_lock);
    if (g_exempt.size() != before) logf(L"spawn blocker: %zu story spawners left alone", g_exempt.size());
}

// ---- headshots ----------------------------------------------------------------------
// Player damage runs through GAS: UCustomCalc_DamageCore::CalculateBaseMagnitude
// calls a helper (found by signature below) that doubles the damage when the
// hit bone equals the target's head bone (a hard-coded `addss xmm7, xmm7`).
// We detour that helper: call it normally, call it again without the hit
// result (no head check), and if the first result shows the head bonus,
// multiply it by the current head multiplier. Lua (BetterGuns) writes
// dlls\combat.txt: head=<multiplier for the held weapon>, pawn=<player>.
// Hits on the player are never boosted. Security-sensitive like the spawn
// blocker: 15 bytes of game code patched in memory, signature-checked.
using DamageHelperFn = float (*)(void* self, void* a2, float damage, void* causer, void* target, void* hit, float armor);
DamageHelperFn g_damage_tramp = nullptr;
std::atomic<uint32_t> g_head_mult_bits{0x3F800000};  // 1.0f
std::atomic<uintptr_t> g_player_pawn{0};
std::atomic<int> g_head_logged{0};
FILETIME g_combat_time{};

float damage_helper_detour(void* self, void* a2, float damage, void* causer, void* target, void* hit, float armor) {
    InHook in_hook(t_in_damage);
    const float d = g_damage_tramp(self, a2, damage, causer, target, hit, armor);
    const uint32_t bits = g_head_mult_bits.load(std::memory_order_relaxed);
    float mult;
    memcpy(&mult, &bits, 4);
    if (!hit || mult == 1.0f || !(mult > 0.0f)) return d;
    if (reinterpret_cast<uintptr_t>(target) == g_player_pawn.load()) return d;  // never buff hits on the player
    const float base = g_damage_tramp(self, a2, damage, causer, target, nullptr, armor);
    if (!(base > 0.0f) || d < base * 1.5f) return d;  // not a head hit
    const float out = d * mult;
    int n = g_head_logged.fetch_add(1) + 1;
    if (n <= 25) logf(L"headshot #%d: damage %.1f (vanilla head %.1f, body %.1f) x%.2f", n, out, d, base, mult);
    return out;
}

bool match_damage_helper(const uint8_t* p) {
    static const uint8_t sig[] = {
        0x48, 0x89, 0x5C, 0x24, 0x10, 0x48, 0x89, 0x74, 0x24, 0x18, 0x57, 0x48, 0x83, 0xEC, 0x50,
        0x48, 0x8B, 0x9C, 0x24, 0x88, 0x00, 0x00, 0x00, 0x49, 0x8B, 0xF9, 0x0F, 0x29, 0x74, 0x24, 0x40,
        0x0F, 0x29, 0x7C, 0x24, 0x30, 0x0F, 0x28, 0xFA};
    return memcmp(p, sig, sizeof(sig)) == 0;
}

// Generic 15-byte prologue detour (the two hooked functions both start with
// 15 bytes of plain register saves). Returns the trampoline or nullptr.
void* detour15(uint8_t* target, void* hook) {
    auto tramp = static_cast<uint8_t*>(VirtualAlloc(nullptr, 64, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE));
    if (!tramp) return nullptr;
    const uint8_t jmp_abs[6] = {0xFF, 0x25, 0x00, 0x00, 0x00, 0x00};  // jmp [rip+0]
    memcpy(tramp, target, 15);
    memcpy(tramp + 15, jmp_abs, 6);
    uint64_t back = reinterpret_cast<uint64_t>(target + 15);
    memcpy(tramp + 21, &back, 8);
    uint8_t patch[15];
    memcpy(patch, jmp_abs, 6);
    uint64_t to = reinterpret_cast<uint64_t>(hook);
    memcpy(patch + 6, &to, 8);
    patch[14] = 0x90;
    DWORD old = 0;
    if (!VirtualProtect(target, 15, PAGE_EXECUTE_READWRITE, &old)) return nullptr;
    memcpy(target, patch, 15);
    VirtualProtect(target, 15, old, &old);
    FlushInstructionCache(GetCurrentProcess(), target, 15);
    return tramp;
}

// ---- animal spawn blocker -------------------------------------------------------------
// Wolves spawned right next to the player (2026-10-18): animal spawn points
// (and the other AActorSpawnerBase spawners) decide through
// AActorSpawnerBase::CheckIfCanSpawn(Pawn, PlayerController, Narrative), when
// they load in with the player already inside their range and when the
// player walks into it. While the spawner is within the animal limit of the
// player it is refused; spawndistance.lua spawns those points later through
// the game's own SpawnAnimals once the player is farther away. Same player
// position and actor layout as the spawner blocker above. 15 prologue bytes
// patched in memory, signature-checked, fails closed.
using CanSpawnFn = bool (*)(void* self, void* pawn, void* pc, void* narrative);
CanSpawnFn g_can_spawn_tramp = nullptr;
std::atomic<int> g_animal_blocked{0};
thread_local int t_in_animal = 0;

// Refused spawners, for spawndistance.lua's deferred spawn (dlls\animal_blocked.txt).
CRITICAL_SECTION g_animal_lock;
std::vector<uintptr_t> g_animal_refused;
bool g_animal_dirty = false;
void animal_refuse(void* self) {
    EnterCriticalSection(&g_animal_lock);
    auto a = reinterpret_cast<uintptr_t>(self);
    if (std::find(g_animal_refused.begin(), g_animal_refused.end(), a) == g_animal_refused.end()) {
        g_animal_refused.push_back(a);
        g_animal_dirty = true;
    }
    LeaveCriticalSection(&g_animal_lock);
}
void write_animal_refused() {
    EnterCriticalSection(&g_animal_lock);
    if (!g_animal_dirty) { LeaveCriticalSection(&g_animal_lock); return; }
    g_animal_dirty = false;
    std::string text;
    char buf[32];
    for (uintptr_t a : g_animal_refused) {
        snprintf(buf, sizeof(buf), "%llX\n", static_cast<unsigned long long>(a));
        text += buf;
    }
    LeaveCriticalSection(&g_animal_lock);
    text += "end\n";
    std::wstring path = g_dir + L"animal_blocked.txt", tmp = path + L".tmp";
    FILE* f = _wfopen(tmp.c_str(), L"wb");
    if (!f) return;
    fwrite(text.data(), 1, text.size(), f);
    fclose(f);
    MoveFileExW(tmp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING);
}

bool can_spawn_detour(void* self, void* pawn, void* pc, void* narrative) {
    InHook in_hook(t_in_animal);
    const long long cm = g_animal_cm.load(std::memory_order_relaxed);
    const int ro = g_root_off.load(std::memory_order_acquire), lo = g_loc_off.load(std::memory_order_acquire);
    // Not calibrated yet (right after loading, when spawn points fire with
    // the player inside their range): refuse; the deferred spawn brings them.
    if (self && cm > 0 && (ro < 0 || lo < 0 || !g_player_known.load(std::memory_order_acquire))) {
        animal_refuse(self);
        int n = g_animal_blocked.fetch_add(1) + 1;
        if (n <= 25) logf(L"animal spawn blocked #%d: player position not known yet (spawns later)", n);
        return false;
    }
    if (self && cm > 0 && ro >= 0 && lo >= 0 && g_player_known.load(std::memory_order_acquire)) {
        void* root = *reinterpret_cast<void* const*>(static_cast<const uint8_t*>(self) + ro);
        if (root) {
            const double* p = reinterpret_cast<const double*>(static_cast<const uint8_t*>(root) + lo);
            const double dx = p[0] - static_cast<double>(g_px.load()), dy = p[1] - static_cast<double>(g_py.load()),
                         dz = p[2] - static_cast<double>(g_pz.load());
            const double d2 = dx * dx + dy * dy + dz * dz;
            if (d2 < static_cast<double>(cm) * static_cast<double>(cm)) {
                animal_refuse(self);
                int n = g_animal_blocked.fetch_add(1) + 1;
                if (n <= 25) logf(L"animal spawn blocked #%d: spawn point %.0f m from you (limit %lld m)", n, sqrt(d2) / 100.0, cm / 100);
                return false;
            }
        }
    }
    return g_can_spawn_tramp(self, pawn, pc, narrative);
}

void install_animal_blocker() {
    InitializeCriticalSection(&g_animal_lock);
    // mov [rsp+8],rbx; mov [rsp+10h],rsi; push rdi; sub rsp,20h;
    // mov rbx,[rcx+2B8h]; mov rsi,r9; movsxd rax,dword [rcx+2C0h]
    static const uint8_t sig[] = {0x48, 0x89, 0x5C, 0x24, 0x08, 0x48, 0x89, 0x74, 0x24, 0x10, 0x57, 0x48, 0x83, 0xEC, 0x20,
                                  0x48, 0x8B, 0x99, 0xB8, 0x02, 0x00, 0x00, 0x49, 0x8B, 0xF1, 0x48, 0x63, 0x81, 0xC0, 0x02,
                                  0x00, 0x00};
    auto base = reinterpret_cast<uint8_t*>(GetModuleHandleW(nullptr));
    auto nt = reinterpret_cast<IMAGE_NT_HEADERS64*>(base + reinterpret_cast<IMAGE_DOS_HEADER*>(base)->e_lfanew);
    auto sec = IMAGE_FIRST_SECTION(nt);
    uint8_t* found = nullptr;
    int matches = 0;
    for (int si = 0; si < nt->FileHeader.NumberOfSections; ++si, ++sec) {
        if (!(sec->Characteristics & IMAGE_SCN_MEM_EXECUTE)) continue;
        uint8_t* q = base + sec->VirtualAddress;
        size_t n = sec->Misc.VirtualSize;
        for (size_t i = 0; i + 64 < n; ++i) {
            if (q[i] == 0x48 && q[i + 15] == 0x48 && q[i + 22] == 0x49 && memcmp(q + i, sig, sizeof(sig)) == 0) {
                found = q + i;
                ++matches;
            }
        }
    }
    if (matches != 1) {
        logf(L"animal spawn blocker OFF: CheckIfCanSpawn signature found %d times (need 1)", matches);
        return;
    }
    g_can_spawn_tramp = reinterpret_cast<CanSpawnFn>(detour15(found, reinterpret_cast<void*>(&can_spawn_detour)));
    if (g_can_spawn_tramp) logf(L"animal spawn blocker hooked CheckIfCanSpawn at exe+0x%llX", static_cast<unsigned long long>(found - base));
    else logf(L"animal spawn blocker OFF: patch failed");
}

void install_headshots() {
    auto base = reinterpret_cast<uint8_t*>(GetModuleHandleW(nullptr));
    auto nt = reinterpret_cast<IMAGE_NT_HEADERS64*>(base + reinterpret_cast<IMAGE_DOS_HEADER*>(base)->e_lfanew);
    auto sec = IMAGE_FIRST_SECTION(nt);
    uint8_t* found = nullptr;
    int matches = 0;
    for (int s = 0; s < nt->FileHeader.NumberOfSections; ++s, ++sec) {
        if (!(sec->Characteristics & IMAGE_SCN_MEM_EXECUTE)) continue;
        uint8_t* p = base + sec->VirtualAddress;
        size_t n = sec->Misc.VirtualSize;
        for (size_t i = 0; i + 64 < n; ++i) {
            if (p[i] == 0x48 && p[i + 15] == 0x48 && p[i + 19] == 0x88 && match_damage_helper(p + i)) {
                found = p + i;
                ++matches;
            }
        }
    }
    if (matches != 1) {
        logf(L"headshots OFF: damage helper signature found %d times (need 1)", matches);
        return;
    }
    g_damage_tramp = reinterpret_cast<DamageHelperFn>(detour15(found, reinterpret_cast<void*>(&damage_helper_detour)));
    if (g_damage_tramp) logf(L"headshots hooked the damage helper at exe+0x%llX", static_cast<unsigned long long>(found - base));
    else logf(L"headshots OFF: patch failed");
}

void read_combat() {
    std::wstring path = g_dir + L"combat.txt";
    WIN32_FILE_ATTRIBUTE_DATA attr{};
    if (!GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &attr)) return;
    if (CompareFileTime(&attr.ftLastWriteTime, &g_combat_time) == 0) return;
    FILE* f = _wfopen(path.c_str(), L"rb");
    if (!f) return;
    char buf[256] = {};
    size_t got = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    std::string text(buf, got);
    if (text.find("\nend\n") == std::string::npos) return;
    g_combat_time = attr.ftLastWriteTime;
    size_t at = text.find("head=");
    if (at != std::string::npos) {
        float m = static_cast<float>(std::strtod(text.c_str() + at + 5, nullptr));
        if (m >= 0.1f && m <= 50.0f) {
            uint32_t bits;
            memcpy(&bits, &m, 4);
            g_head_mult_bits.store(bits);
        }
    }
    at = text.find("pawn=");
    if (at != std::string::npos) g_player_pawn.store(std::strtoull(text.c_str() + at + 5, nullptr, 16));
}

// ---- toolbelt (knife in hotbar) -------------------------------------------------------
// UInteractionFunctionLibrary::IsHeldToolCompatible(Actor, HeldType, HeldTier)
// decides the prompt and whether the interaction may start; the HUD and
// interaction code call it natively, so the Lua hook never saw electrical
// boxes (2026-10-17). Detour: if the original refuses, ask again as if a
// top-tier knife were held; if that passes (the target wants a knife) and the
// player has any knife in the hotbar, allow it. The unlock itself
// (UPadlock::TryToUnlock) is still adjusted by Lua, with the durability cost.
// Lua (Toolbelt) writes dlls\toolbelt.txt: knife=<EToolType value>, has=0/1.
using ToolCheckFn = bool (*)(void* actor, uint8_t type, uint8_t tier);
ToolCheckFn g_tool_tramp = nullptr;
std::atomic<int> g_knife_type{-1};
std::atomic<bool> g_has_knife{false};
std::atomic<int> g_tool_logged{0};
FILETIME g_tool_time{};

bool tool_check_detour(void* actor, uint8_t type, uint8_t tier) {
    InHook in_hook(t_in_tool);
    if (g_tool_tramp(actor, type, tier)) return true;
    const int knife = g_knife_type.load(std::memory_order_relaxed);
    if (knife < 0 || !g_has_knife.load(std::memory_order_relaxed) || type == static_cast<uint8_t>(knife)) {
        // Holding the knife already: the tier rule is Lua's (TryToUnlock).
        if (!(knife >= 0 && type == static_cast<uint8_t>(knife) && g_tool_tramp(actor, type, 0xFF))) return false;
        return true;
    }
    if (g_tool_tramp(actor, static_cast<uint8_t>(knife), 0xFF)) {
        int n = g_tool_logged.fetch_add(1) + 1;
        if (n <= 10) logf(L"toolbelt: knife in hotbar counts for target %p (hand had tool %u tier %u)", actor, type, tier);
        return true;
    }
    return false;
}

void install_toolbelt() {
    static const int16_t sig[] = {
        0x48, 0x89, 0x5C, 0x24, 0x08, 0x48, 0x89, 0x6C, 0x24, 0x10, 0x48, 0x89, 0x74, 0x24, 0x18, 0x57,
        0x48, 0x83, 0xEC, 0x20, 0x41, 0x0F, 0xB6, 0xF0, 0x0F, 0xB6, 0xEA, 0x48, 0x8B, 0xF9, 0x48, 0x85,
        0xC9, 0x74, -1, 0x8B, 0x41, 0x08, 0xC1, 0xE8, 0x1E};
    auto base = reinterpret_cast<uint8_t*>(GetModuleHandleW(nullptr));
    auto nt = reinterpret_cast<IMAGE_NT_HEADERS64*>(base + reinterpret_cast<IMAGE_DOS_HEADER*>(base)->e_lfanew);
    auto sec = IMAGE_FIRST_SECTION(nt);
    uint8_t* found = nullptr;
    int matches = 0;
    for (int s = 0; s < nt->FileHeader.NumberOfSections; ++s, ++sec) {
        if (!(sec->Characteristics & IMAGE_SCN_MEM_EXECUTE)) continue;
        uint8_t* p = base + sec->VirtualAddress;
        size_t n = sec->Misc.VirtualSize;
        for (size_t i = 0; i + 64 < n; ++i) {
            if (p[i] != 0x48 || p[i + 20] != 0x41 || p[i + 24] != 0x0F) continue;
            bool ok = true;
            for (size_t k = 0; k < sizeof(sig) / sizeof(sig[0]); ++k) {
                if (sig[k] >= 0 && p[i + k] != static_cast<uint8_t>(sig[k])) { ok = false; break; }
            }
            if (ok) { found = p + i; ++matches; }
        }
    }
    if (matches != 1) {
        logf(L"toolbelt native OFF: IsHeldToolCompatible signature found %d times (need 1)", matches);
        return;
    }
    // First 15 bytes = three register saves (instruction boundary).
    g_tool_tramp = reinterpret_cast<ToolCheckFn>(detour15(found, reinterpret_cast<void*>(&tool_check_detour)));
    if (g_tool_tramp) logf(L"toolbelt hooked IsHeldToolCompatible at exe+0x%llX", static_cast<unsigned long long>(found - base));
    else logf(L"toolbelt native OFF: patch failed");
}

void read_toolbelt() {
    std::wstring path = g_dir + L"toolbelt.txt";
    WIN32_FILE_ATTRIBUTE_DATA attr{};
    if (!GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &attr)) return;
    if (CompareFileTime(&attr.ftLastWriteTime, &g_tool_time) == 0) return;
    FILE* f = _wfopen(path.c_str(), L"rb");
    if (!f) return;
    char buf[128] = {};
    size_t got = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    std::string text(buf, got);
    if (text.find("\nend\n") == std::string::npos) return;
    g_tool_time = attr.ftLastWriteTime;
    size_t at = text.find("knife=");
    if (at != std::string::npos) g_knife_type.store(static_cast<int>(std::strtol(text.c_str() + at + 6, nullptr, 10)));
    at = text.find("has=");
    if (at != std::string::npos) g_has_knife.store(text[at + 4] == '1');
}

// ---- hall reverb on gunshots --------------------------------------------------------
// User 2026-10-18: shots should sound like a big hall. FMOD mixes the game's
// audio, so a real reverb is added inside FMOD: an "SFX Reverb" DSP on the
// player's gunshot bus (bus path ending in "Weapon_Shot"). The Studio system
// pointer comes from FMOD::Studio::System::update, which the exe calls every
// frame through its delay-import table: that slot is pointed at our wrapper,
// which does the setup on the game's own audio-update call and then calls
// the real update. Only a pointer in the exe's import table changes, no code.
// Lua (BetterGuns) writes dlls\reverb.txt: on, decay (ms), wet/dry (dB),
// early (ms), late (ms), highcut (Hz), mix (early/late %).
using FmodResult = int;
using StudioUpdateFn = FmodResult (*)(void* system);
StudioUpdateFn g_studio_update = nullptr;
void* g_studio_system = nullptr;
HMODULE g_fmod = nullptr, g_fmod_studio = nullptr;

struct ReverbParams {
    bool on = false;
    float decay = 3900, early = 20, late = 29, highcut = 5650, mix = 80, wet = -8, dry = 0;
};
ReverbParams g_rev_want, g_rev_applied;
bool g_rev_dirty = false;
void* g_rev_dsp = nullptr;
void* g_rev_bus = nullptr;
int g_rev_type = -1;       // FMOD_DSP_TYPE value whose name is "SFX Reverb"
int g_rev_fail = 0;
CRITICAL_SECTION g_rev_lock;
FILETIME g_rev_time{};

template <typename T> T fmod_fn(HMODULE m, const char* name) {
    return m ? reinterpret_cast<T>(GetProcAddress(m, name)) : nullptr;
}

// Finds the bus whose path ends with "/Weapon_Shot" in the loaded banks.
void* find_shot_bus(void* sys) {
    auto bank_count = fmod_fn<FmodResult (*)(void*, int*)>(g_fmod_studio, "FMOD_Studio_System_GetBankCount");
    auto bank_list = fmod_fn<FmodResult (*)(void*, void**, int, int*)>(g_fmod_studio, "FMOD_Studio_System_GetBankList");
    auto bus_count = fmod_fn<FmodResult (*)(void*, int*)>(g_fmod_studio, "FMOD_Studio_Bank_GetBusCount");
    auto bus_list = fmod_fn<FmodResult (*)(void*, void**, int, int*)>(g_fmod_studio, "FMOD_Studio_Bank_GetBusList");
    auto bus_path = fmod_fn<FmodResult (*)(void*, char*, int, int*)>(g_fmod_studio, "FMOD_Studio_Bus_GetPath");
    if (!bank_count || !bank_list || !bus_count || !bus_list || !bus_path) return nullptr;
    int nb = 0;
    if (bank_count(sys, &nb) != 0 || nb <= 0) return nullptr;
    std::vector<void*> banks(nb);
    if (bank_list(sys, banks.data(), nb, &nb) != 0) return nullptr;
    for (int b = 0; b < nb; ++b) {
        int n = 0;
        if (bus_count(banks[b], &n) != 0 || n <= 0) continue;
        std::vector<void*> buses(n);
        if (bus_list(banks[b], buses.data(), n, &n) != 0) continue;
        for (int i = 0; i < n; ++i) {
            char path[256] = {};
            int got = 0;
            if (bus_path(buses[i], path, sizeof(path), &got) != 0) continue;
            size_t len = strlen(path);
            const char suffix[] = "/Weapon_Shot";
            if (len >= sizeof(suffix) - 1 && strcmp(path + len - (sizeof(suffix) - 1), suffix) == 0) {
                logf(L"hall reverb: gunshot bus %hs", path);
                return buses[i];
            }
        }
    }
    return nullptr;
}

void apply_reverb_params(void* dsp, const ReverbParams& p) {
    auto set = fmod_fn<FmodResult (*)(void*, int, float)>(g_fmod, "FMOD_DSP_SetParameterFloat");
    if (!set) return;
    // FMOD_DSP_SFXREVERB parameter order (FMOD 2.03).
    set(dsp, 0, p.decay);
    set(dsp, 1, p.early);
    set(dsp, 2, p.late);
    set(dsp, 9, p.highcut);
    set(dsp, 10, p.mix);
    set(dsp, 11, p.on ? p.wet : -80.0f);
    set(dsp, 12, p.dry);
    auto bypass = fmod_fn<FmodResult (*)(void*, int)>(g_fmod, "FMOD_DSP_SetBypass");
    if (bypass) bypass(dsp, p.on ? 0 : 1);
}

// Creates the reverb DSP; the type is found by name, not by enum number.
void* create_reverb(void* core) {
    auto create = fmod_fn<FmodResult (*)(void*, int, void**)>(g_fmod, "FMOD_System_CreateDSPByType");
    auto info = fmod_fn<FmodResult (*)(void*, char*, unsigned*, int*, int*, int*)>(g_fmod, "FMOD_DSP_GetInfo");
    auto release = fmod_fn<FmodResult (*)(void*)>(g_fmod, "FMOD_DSP_Release");
    if (!create || !info || !release) return nullptr;
    auto try_type = [&](int t) -> void* {
        void* dsp = nullptr;
        if (create(core, t, &dsp) != 0 || !dsp) return nullptr;
        char name[64] = {};
        unsigned ver = 0;
        int ch = 0, w = 0, h = 0;
        info(dsp, name, &ver, &ch, &w, &h);
        if (strstr(name, "SFX Reverb")) return dsp;
        release(dsp);
        return nullptr;
    };
    if (g_rev_type >= 0) return try_type(g_rev_type);
    for (int t = 19; t < 40; ++t) {  // 19 = SFXREVERB in FMOD 2.02/2.03; scan in case the enum moved
        if (void* d = try_type(t)) { g_rev_type = t; return d; }
    }
    for (int t = 1; t < 19; ++t) {
        if (void* d = try_type(t)) { g_rev_type = t; return d; }
    }
    return nullptr;
}

void reverb_setup(void* sys) {
    if (g_rev_fail >= 99) return;  // permanent failure, logged once
    static unsigned frame = 0;
    if (!g_rev_dsp && (++frame % 60) != 0) return;  // setup attempts about once a second
    EnterCriticalSection(&g_rev_lock);
    ReverbParams want = g_rev_want;
    bool dirty = g_rev_dirty;
    g_rev_dirty = false;
    LeaveCriticalSection(&g_rev_lock);
    if (!g_rev_dsp) {
        if (!want.on) return;
        auto lock = fmod_fn<FmodResult (*)(void*)>(g_fmod_studio, "FMOD_Studio_Bus_LockChannelGroup");
        auto get_group = fmod_fn<FmodResult (*)(void*, void**)>(g_fmod_studio, "FMOD_Studio_Bus_GetChannelGroup");
        auto get_core = fmod_fn<FmodResult (*)(void*, void**)>(g_fmod_studio, "FMOD_Studio_System_GetCoreSystem");
        auto add = fmod_fn<FmodResult (*)(void*, int, void*)>(g_fmod, "FMOD_ChannelGroup_AddDSP");
        if (!lock || !get_group || !get_core || !add) { g_rev_fail = 99; logf(L"hall reverb OFF: FMOD exports missing"); return; }
        if (!g_rev_bus) {
            g_rev_bus = find_shot_bus(sys);
            if (!g_rev_bus) return;  // banks not loaded yet; retried
            lock(g_rev_bus);  // keeps the bus's channel group alive; it exists after the next update
            return;
        }
        void* group = nullptr;
        if (get_group(g_rev_bus, &group) != 0 || !group) return;  // not created yet
        void* core = nullptr;
        if (get_core(sys, &core) != 0 || !core) return;
        void* dsp = create_reverb(core);
        if (!dsp) { g_rev_fail = 99; logf(L"hall reverb OFF: no SFX Reverb DSP type found"); return; }
        apply_reverb_params(dsp, want);
        int r = add(group, 0, dsp);
        if (r != 0) { g_rev_fail = 99; logf(L"hall reverb OFF: AddDSP failed (%d)", r); return; }
        g_rev_dsp = dsp;
        g_rev_applied = want;
        logf(L"hall reverb ON (DSP type %d): decay %.0f ms, wet %.1f dB, dry %.1f dB, high cut %.0f Hz", g_rev_type,
             want.decay, want.wet, want.dry, want.highcut);
        return;
    }
    if (dirty) {
        apply_reverb_params(g_rev_dsp, want);
        g_rev_applied = want;
    }
}

FmodResult studio_update_hook(void* sys) {
    if (!g_studio_system) g_studio_system = sys;
    if (sys == g_studio_system) reverb_setup(sys);
    return g_studio_update(sys);
}

// The game loads the FMOD dlls (delay-loaded) after main.dll starts, so this
// is retried from tick() until they are there (2026-10-18: the first version
// ran once at startup and always found them missing).
int g_reverb_state = 0;  // 0 = waiting for FMOD, 1 = hooked, 2 = gave up
void install_reverb() {
    if (g_reverb_state != 0) return;
    static const char kUpdate[] = "?update@System@Studio@FMOD@@QEAA?AW4FMOD_RESULT@@XZ";
    g_fmod = GetModuleHandleW(L"fmod.dll");
    g_fmod_studio = GetModuleHandleW(L"fmodstudio.dll");
    if (!g_fmod || !g_fmod_studio) return;  // not loaded yet
    g_reverb_state = 2;  // any early return below is final
    auto real = reinterpret_cast<StudioUpdateFn>(GetProcAddress(g_fmod_studio, kUpdate));
    if (!real) { logf(L"hall reverb OFF: Studio update export missing"); return; }
    auto base = reinterpret_cast<uint8_t*>(GetModuleHandleW(nullptr));
    auto nt = reinterpret_cast<IMAGE_NT_HEADERS64*>(base + reinterpret_cast<IMAGE_DOS_HEADER*>(base)->e_lfanew);
    const auto& dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT];
    if (!dir.VirtualAddress) { logf(L"hall reverb OFF: exe has no delay imports"); return; }
    for (auto d = reinterpret_cast<IMAGE_DELAYLOAD_DESCRIPTOR*>(base + dir.VirtualAddress); d->DllNameRVA; ++d) {
        const char* dll = reinterpret_cast<const char*>(base + d->DllNameRVA);
        if (_stricmp(dll, "fmodstudio.dll") != 0) continue;
        auto names = reinterpret_cast<IMAGE_THUNK_DATA64*>(base + d->ImportNameTableRVA);
        auto slots = reinterpret_cast<uint64_t*>(base + d->ImportAddressTableRVA);
        for (int i = 0; names[i].u1.AddressOfData; ++i) {
            if (IMAGE_SNAP_BY_ORDINAL64(names[i].u1.Ordinal)) continue;
            auto by_name = reinterpret_cast<IMAGE_IMPORT_BY_NAME*>(base + names[i].u1.AddressOfData);
            if (strcmp(reinterpret_cast<const char*>(by_name->Name), kUpdate) != 0) continue;
            g_studio_update = real;
            DWORD old = 0;
            if (!VirtualProtect(&slots[i], 8, PAGE_READWRITE, &old)) { logf(L"hall reverb OFF: import slot locked"); return; }
            slots[i] = reinterpret_cast<uint64_t>(&studio_update_hook);
            VirtualProtect(&slots[i], 8, old, &old);
            logf(L"hall reverb: hooked FMOD Studio update (delay-import slot %d)", i);
            g_reverb_state = 1;
            return;
        }
    }
    logf(L"hall reverb OFF: Studio update import not found");
}

void read_reverb() {
    std::wstring path = g_dir + L"reverb.txt";
    WIN32_FILE_ATTRIBUTE_DATA attr{};
    if (!GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &attr)) return;
    if (CompareFileTime(&attr.ftLastWriteTime, &g_rev_time) == 0) return;
    FILE* f = _wfopen(path.c_str(), L"rb");
    if (!f) return;
    char buf[512] = {};
    size_t got = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    std::string text(buf, got);
    if (text.find("\nend\n") == std::string::npos) return;
    g_rev_time = attr.ftLastWriteTime;
    ReverbParams p = g_rev_want;
    auto num = [&](const char* key, float lo, float hi, float& out) {
        std::string k = std::string("\n") + key + "=";
        size_t at = ("\n" + text).find(k);
        if (at == std::string::npos) return;
        float v = static_cast<float>(std::strtod(text.c_str() + at + k.size() - 1, nullptr));
        if (v >= lo && v <= hi) out = v;
    };
    float on = p.on ? 1.0f : 0.0f;
    num("on", 0, 1, on);
    p.on = on > 0.5f;
    num("decay", 100, 20000, p.decay);
    num("early", 0, 300, p.early);
    num("late", 0, 100, p.late);
    num("highcut", 20, 20000, p.highcut);
    num("mix", 0, 100, p.mix);
    num("wet", -80, 20, p.wet);
    num("dry", -80, 20, p.dry);
    EnterCriticalSection(&g_rev_lock);
    g_rev_want = p;
    g_rev_dirty = true;
    LeaveCriticalSection(&g_rev_lock);
}

// ---- fast travel food cost ------------------------------------------------------------
// User 2026-10-18: fast travel costs food. The map's confirm calls
// UFastTravelAccessPoint::TravelTo(Actor, PlayerController) natively, so no
// Lua hook sees the trip. This detours TravelTo: with less food than the
// cost (both from travelcost.lua via dlls\travel.txt) the trip is refused;
// otherwise it runs and a paid counter goes up, which this writes to
// dlls\travel_paid.txt for travelcost.lua to take the food. The function
// starts with `test r8,r8; je far` (a relative jump), so the trampoline
// rebuilds that check with an absolute jump. Signature-checked, fails closed.
using TravelToFn = void (*)(void* self, void* actor, void* pc);
TravelToFn g_travel_tramp = nullptr;
std::atomic<int> g_travel_food{-1}, g_travel_cost{0};
std::atomic<int> g_travel_paid{0}, g_travel_refused{0};
int g_travel_written = -1;
FILETIME g_travel_time{};

void travel_detour(void* self, void* actor, void* pc) {
    const int cost = g_travel_cost.load(), food = g_travel_food.load();
    if (pc && cost > 0 && food >= 0 && food < cost) {
        int n = g_travel_refused.fetch_add(1) + 1;
        logf(L"fast travel refused #%d: %d food on you, trip costs %d", n, food, cost);
        return;
    }
    if (pc && cost > 0) g_travel_paid.fetch_add(1);
    g_travel_tramp(self, actor, pc);
}

void install_travel_cost() {
    // test r8,r8 | je rel32 | push rbp | push rsi | push r14 | sub rsp,0D0h | mov rax,[rip+x] | xor rax,rsp
    static const int16_t sig[] = {0x4D, 0x85, 0xC0, 0x0F, 0x84, -1, -1, -1, -1, 0x55, 0x56, 0x41, 0x56,
                                  0x48, 0x81, 0xEC, 0xD0, 0x00, 0x00, 0x00, 0x48, 0x8B, 0x05, -1, -1, -1, -1,
                                  0x48, 0x33, 0xC4, 0x48, 0x89};
    auto base = reinterpret_cast<uint8_t*>(GetModuleHandleW(nullptr));
    auto nt = reinterpret_cast<IMAGE_NT_HEADERS64*>(base + reinterpret_cast<IMAGE_DOS_HEADER*>(base)->e_lfanew);
    auto sec = IMAGE_FIRST_SECTION(nt);
    uint8_t* found = nullptr;
    int matches = 0;
    for (int si = 0; si < nt->FileHeader.NumberOfSections; ++si, ++sec) {
        if (!(sec->Characteristics & IMAGE_SCN_MEM_EXECUTE)) continue;
        uint8_t* q = base + sec->VirtualAddress;
        size_t n = sec->Misc.VirtualSize;
        for (size_t i = 0; i + 64 < n; ++i) {
            if (q[i] != 0x4D || q[i + 1] != 0x85 || q[i + 9] != 0x55) continue;
            bool ok = true;
            for (size_t k = 0; k < sizeof(sig) / sizeof(sig[0]); ++k) {
                if (sig[k] >= 0 && q[i + k] != static_cast<uint8_t>(sig[k])) { ok = false; break; }
            }
            if (ok) { found = q + i; ++matches; }
        }
    }
    if (matches != 1) {
        logf(L"fast travel cost OFF: TravelTo signature found %d times (need 1)", matches);
        return;
    }
    int32_t rel = 0;
    memcpy(&rel, found + 5, 4);
    const uint64_t je_target = reinterpret_cast<uint64_t>(found + 9) + rel;
    auto tramp = static_cast<uint8_t*>(VirtualAlloc(nullptr, 64, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE));
    if (!tramp) { logf(L"fast travel cost OFF: VirtualAlloc failed"); return; }
    uint8_t* t = tramp;
    const uint8_t test_r8[] = {0x4D, 0x85, 0xC0};
    memcpy(t, test_r8, 3); t += 3;
    const uint8_t jne_skip[] = {0x75, 0x0E};                 // jne +14 (over the absolute jmp)
    memcpy(t, jne_skip, 2); t += 2;
    const uint8_t jmp_abs[] = {0xFF, 0x25, 0x00, 0x00, 0x00, 0x00};
    memcpy(t, jmp_abs, 6); t += 6;
    memcpy(t, &je_target, 8); t += 8;
    memcpy(t, found + 9, 11); t += 11;                       // push rbp; push rsi; push r14; sub rsp,0D0h
    memcpy(t, jmp_abs, 6); t += 6;
    const uint64_t back = reinterpret_cast<uint64_t>(found + 20);
    memcpy(t, &back, 8);
    g_travel_tramp = reinterpret_cast<TravelToFn>(tramp);

    uint8_t patch[20];
    memcpy(patch, jmp_abs, 6);
    const uint64_t to = reinterpret_cast<uint64_t>(&travel_detour);
    memcpy(patch + 6, &to, 8);
    memset(patch + 14, 0x90, 6);
    DWORD old = 0;
    if (!VirtualProtect(found, 20, PAGE_EXECUTE_READWRITE, &old)) { logf(L"fast travel cost OFF: VirtualProtect failed"); return; }
    memcpy(found, patch, 20);
    VirtualProtect(found, 20, old, &old);
    FlushInstructionCache(GetCurrentProcess(), found, 20);
    logf(L"fast travel cost hooked TravelTo at exe+0x%llX", static_cast<unsigned long long>(found - base));
}

void read_travel() {
    std::wstring path = g_dir + L"travel.txt";
    WIN32_FILE_ATTRIBUTE_DATA attr{};
    if (GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &attr) &&
        CompareFileTime(&attr.ftLastWriteTime, &g_travel_time) != 0) {
        FILE* f = _wfopen(path.c_str(), L"rb");
        if (f) {
            char buf[128] = {};
            size_t got = fread(buf, 1, sizeof(buf) - 1, f);
            fclose(f);
            std::string text(buf, got);
            if (text.find("\nend\n") != std::string::npos) {
                g_travel_time = attr.ftLastWriteTime;
                size_t at = text.find("food=");
                if (at != std::string::npos) g_travel_food.store(static_cast<int>(std::strtol(text.c_str() + at + 5, nullptr, 10)));
                at = text.find("cost=");
                if (at != std::string::npos) g_travel_cost.store(static_cast<int>(std::strtol(text.c_str() + at + 5, nullptr, 10)));
            }
        }
    }
    // Trips the player paid for (and refused ones), for travelcost.lua.
    const int paid = g_travel_paid.load(), refused = g_travel_refused.load();
    const int sig = paid * 100000 + refused;
    if (sig != g_travel_written) {
        g_travel_written = sig;
        std::wstring out = g_dir + L"travel_paid.txt", tmp = out + L".tmp";
        FILE* o = _wfopen(tmp.c_str(), L"wb");
        if (o) {
            char line[96];
            int len = snprintf(line, sizeof(line), "paid=%d\nrefused=%d\nend\n", paid, refused);
            fwrite(line, 1, len, o);
            fclose(o);
            MoveFileExW(tmp.c_str(), out.c_str(), MOVEFILE_REPLACE_EXISTING);
        }
    }
}

// ---- crash report -------------------------------------------------------------------
// With Modules.diagnostics = 1 (config.lua), a vectored exception handler
// writes dlls\crash_report.txt the moment a fatal exception happens, before
// the game's own crash reporter: code, faulting module+offset, registers, a
// scan of the stack for return addresses (module+offset), which of our
// native hooks was running on that thread, and the last lines of the Lua
// flight recorder (dlls\flight.txt). Armed only once the player is in the
// world (startup throws harmless first-chance exceptions). At most 3 reports
// per session; a first-chance exception the game handles also gets written,
// marked as such. The previous session's report is kept as
// crash_report_prev.txt.
bool g_diag = true;
std::atomic<int> g_crash_reports{0};

void module_of(uintptr_t addr, char* name, size_t cap, uintptr_t* off) {
    HMODULE h = nullptr;
    name[0] = 0;
    *off = addr;
    if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           reinterpret_cast<LPCSTR>(addr), &h) && h) {
        char path[MAX_PATH];
        DWORD n = GetModuleFileNameA(h, path, MAX_PATH);
        const char* base = path;
        for (DWORD i = 0; i < n; ++i) if (path[i] == '\\') base = path + i + 1;
        snprintf(name, cap, "%s", n ? base : "?");
        *off = addr - reinterpret_cast<uintptr_t>(h);
    }
}

void crash_write(HANDLE f, const char* fmt, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n > 0) {
        DWORD w = 0;
        WriteFile(f, buf, static_cast<DWORD>(n < static_cast<int>(sizeof(buf)) ? n : sizeof(buf) - 1), &w, nullptr);
    }
}

LONG CALLBACK crash_handler(EXCEPTION_POINTERS* ep) {
    const DWORD code = ep->ExceptionRecord->ExceptionCode;
    if (code != EXCEPTION_ACCESS_VIOLATION && code != EXCEPTION_ILLEGAL_INSTRUCTION &&
        code != EXCEPTION_PRIV_INSTRUCTION && code != EXCEPTION_INT_DIVIDE_BY_ZERO &&
        code != EXCEPTION_STACK_OVERFLOW && code != EXCEPTION_ARRAY_BOUNDS_EXCEEDED)
        return EXCEPTION_CONTINUE_SEARCH;
    if (!g_crash_armed.load() || g_crash_reports.fetch_add(1) >= 3) return EXCEPTION_CONTINUE_SEARCH;
    std::wstring path = g_dir + L"crash_report.txt";
    HANDLE f = CreateFileW(path.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (f == INVALID_HANDLE_VALUE) return EXCEPTION_CONTINUE_SEARCH;
    SYSTEMTIME st;
    GetLocalTime(&st);
    const CONTEXT* c = ep->ContextRecord;
    char mod[128];
    uintptr_t off = 0;
    module_of(reinterpret_cast<uintptr_t>(ep->ExceptionRecord->ExceptionAddress), mod, sizeof(mod), &off);
    crash_write(f, "==== %02d:%02d:%02d.%03d exception 0x%08lX in %s+0x%llX (thread %lu)%s\n", st.wHour, st.wMinute,
                st.wSecond, st.wMilliseconds, code, mod, static_cast<unsigned long long>(off), GetCurrentThreadId(),
                g_crash_reports.load() > 1 ? " [another report this session: earlier ones may have been handled]" : "");
    if (code == EXCEPTION_ACCESS_VIOLATION && ep->ExceptionRecord->NumberParameters >= 2) {
        crash_write(f, "access: %s address 0x%llX\n",
                    ep->ExceptionRecord->ExceptionInformation[0] == 0 ? "read" :
                    ep->ExceptionRecord->ExceptionInformation[0] == 1 ? "write" : "execute",
                    static_cast<unsigned long long>(ep->ExceptionRecord->ExceptionInformation[1]));
    }
    crash_write(f, "our native hooks on this thread: spawn blocker %d, headshots %d, toolbelt %d\n", t_in_spawn,
                t_in_damage, t_in_tool);
    if (code == EXCEPTION_STACK_OVERFLOW) {  // little stack left: stop here
        CloseHandle(f);
        return EXCEPTION_CONTINUE_SEARCH;
    }
    crash_write(f, "rax %016llX rbx %016llX rcx %016llX rdx %016llX\nrsi %016llX rdi %016llX rbp %016llX rsp %016llX\n"
                   "r8  %016llX r9  %016llX r10 %016llX r11 %016llX\nr12 %016llX r13 %016llX r14 %016llX r15 %016llX\n",
                c->Rax, c->Rbx, c->Rcx, c->Rdx, c->Rsi, c->Rdi, c->Rbp, c->Rsp, c->R8, c->R9, c->R10, c->R11, c->R12,
                c->R13, c->R14, c->R15);
    crash_write(f, "stack (return-address candidates, newest first):\n");
    const uintptr_t* sp = reinterpret_cast<const uintptr_t*>(c->Rsp);
    int shown = 0;
    for (int i = 0; i < 1024 && shown < 48; ++i) {
        if ((i & 511) == 0 && !readable(sp + i, 512 * sizeof(uintptr_t))) break;
        uintptr_t v = sp[i];
        if (v < 0x10000) continue;
        MEMORY_BASIC_INFORMATION mbi{};
        if (!VirtualQuery(reinterpret_cast<void*>(v), &mbi, sizeof(mbi))) continue;
        if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY))) continue;
        module_of(v, mod, sizeof(mod), &off);
        if (!mod[0]) continue;
        crash_write(f, "  %s+0x%llX\n", mod, static_cast<unsigned long long>(off));
        ++shown;
    }
    // Tail of the Lua flight recorder.
    std::wstring fl = g_dir + L"flight.txt";
    HANDLE ff = CreateFileW(fl.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (ff != INVALID_HANDLE_VALUE) {
        static char tail[6144];
        LARGE_INTEGER size{};
        GetFileSizeEx(ff, &size);
        LARGE_INTEGER pos{};
        pos.QuadPart = size.QuadPart > static_cast<LONGLONG>(sizeof(tail)) ? size.QuadPart - sizeof(tail) : 0;
        SetFilePointerEx(ff, pos, nullptr, FILE_BEGIN);
        DWORD got = 0;
        ReadFile(ff, tail, sizeof(tail), &got, nullptr);
        CloseHandle(ff);
        crash_write(f, "flight recorder (last lines):\n");
        DWORD w = 0;
        WriteFile(f, tail, got, &w, nullptr);
    }
    crash_write(f, "\n");
    CloseHandle(f);
    return EXCEPTION_CONTINUE_SEARCH;
}

void install_crash_report() {
    std::wstring cfg = g_dir + L"..\\config.lua";
    FILE* in = _wfopen(cfg.c_str(), L"rb");
    if (in) {
        std::string text;
        char buf[4096];
        size_t n;
        while ((n = fread(buf, 1, sizeof(buf), in)) > 0) text.append(buf, n);
        fclose(in);
        size_t at = text.find("\n        diagnostics");
        if (at == std::string::npos) at = text.find("diagnostics ");
        if (at != std::string::npos) {
            size_t eq = text.find('=', at);
            if (eq != std::string::npos) {
                size_t v = text.find_first_not_of(" \t", eq + 1);
                if (v != std::string::npos && text[v] == '0') g_diag = false;
            }
        }
    }
    if (!g_diag) { logf(L"diagnostics off: no crash report"); return; }
    std::wstring cur = g_dir + L"crash_report.txt", prev = g_dir + L"crash_report_prev.txt";
    if (GetFileAttributesW(cur.c_str()) != INVALID_FILE_ATTRIBUTES) MoveFileExW(cur.c_str(), prev.c_str(), MOVEFILE_REPLACE_EXISTING);
    AddVectoredExceptionHandler(1, crash_handler);
    logf(L"crash report ready (armed once in the world): dlls\\crash_report.txt");
}

// ---- survival rates (was the closed SurvivalTweaks.dll) -----------------------------
// Scales the player's own stat losses: stamina, hunger, energy, health damage
// and body warmth. Positive changes, other characters and non-additive changes
// stay vanilla.
// Every GAS change passes through the owning attribute set's virtual
// PreGameplayEffectExecute(FGameplayEffectModCallbackData&). The Stamina set
// (Stamina, Hunger, Energy) overrides it; the Health and Temperature sets use
// the base UAttributeSet version (`mov al,1; ret`). Those three vtable slots
// are pointed at our hooks, which call the game's function first, then scale
// the change: callback data +0x08 -> FGameplayModifierEvaluatedData
// (Attribute at +0x00 with AttributeName FString first, ModifierOp at +0x38,
// Magnitude float at +0x3C), +0x10 -> target ability system component.
// No game addresses are hardcoded: Lua (survivaltweaks.lua) writes
// dlls\survival.txt with the player's ASC, one live object of each attribute
// set (their vtables are read from them) and the multipliers. The slot is the
// one where the Stamina set holds its own PreGameplayEffectExecute (checked by
// its first bytes) and the Health and Temperature sets both hold the base
// function. Anything unexpected: no hook (vanilla). Only vtable entries change.
using PreExecFn = bool (*)(void* self, void* data);
PreExecFn g_pre_stamina = nullptr, g_pre_base = nullptr;
std::atomic<uintptr_t> g_survival_asc{0};
// stamina, hunger, energy, health, warmth (float bits, 1.0 = vanilla)
std::atomic<uint32_t> g_surv_mult[5] = {0x3F800000, 0x3F800000, 0x3F800000, 0x3F800000, 0x3F800000};
std::atomic<int> g_surv_logged[5]{};   // per stat, so hunger's steady ticks do not hide the others
bool g_survival_hooked = false, g_survival_failed = false;
FILETIME g_survival_time{};
uintptr_t g_set_stamina = 0, g_set_health = 0, g_set_temp = 0;

const wchar_t* const kSurvivalNames[5] = {L"Stamina", L"Hunger", L"Energy", L"Health", L"BodyWarmth"};

int survival_index(const uint8_t* evaluated) {
    // FGameplayAttribute.AttributeName: FString { wchar_t* data; int num; int max }.
    const wchar_t* name = *reinterpret_cast<wchar_t* const*>(evaluated);
    const int num = *reinterpret_cast<const int*>(evaluated + 8);
    if (!name || num <= 1 || num > 64 || !readable(name, num * sizeof(wchar_t))) return -1;
    for (int i = 0; i < 5; ++i) {
        if (wcscmp(name, kSurvivalNames[i]) == 0) return i;
    }
    return -1;
}

void survival_scale(void* data) {
    auto d = static_cast<uint8_t*>(data);
    void* target = *reinterpret_cast<void**>(d + 0x10);
    const uintptr_t asc = g_survival_asc.load(std::memory_order_relaxed);
    if (!asc || reinterpret_cast<uintptr_t>(target) != asc) return;  // the player's own stats only
    auto evaluated = *reinterpret_cast<uint8_t**>(d + 0x08);
    if (!evaluated || evaluated[0x38] != 0) return;  // additive changes only
    float& magnitude = *reinterpret_cast<float*>(evaluated + 0x3C);
    if (!(magnitude < 0.0f)) return;                  // losses only
    const int i = survival_index(evaluated);
    if (i < 0) {
        // Other attributes (alcohol, durability...) are expected here; log a
        // few so a renamed attribute shows up.
        static std::atomic<int> other_logged{0};
        if (other_logged.fetch_add(1) < 5) {
            const wchar_t* name = *reinterpret_cast<wchar_t* const*>(evaluated);
            const int num = *reinterpret_cast<const int*>(evaluated + 8);
            bool ok = name && num > 1 && num <= 64 && readable(name, num * sizeof(wchar_t));
            logf(L"survival: loss on %ls left vanilla", ok ? name : L"(unnamed attribute)");
        }
        return;
    }
    const uint32_t bits = g_surv_mult[i].load(std::memory_order_relaxed);
    float mult;
    memcpy(&mult, &bits, 4);
    if (mult == 1.0f) return;
    const float before = magnitude;
    magnitude = before * mult;
    int n = g_surv_logged[i].fetch_add(1) + 1;
    if (n <= 5) logf(L"survival: %ls %.3f -> %.3f (x%.2f)", kSurvivalNames[i], before, magnitude, mult);
}

bool pre_stamina_hook(void* self, void* data) {
    const bool r = g_pre_stamina(self, data);
    survival_scale(data);
    return r;
}

bool pre_base_hook(void* self, void* data) {
    const bool r = g_pre_base(self, data);
    survival_scale(data);
    return r;
}

bool code_matches(uintptr_t fn, const uint8_t* sig, size_t n) {
    return fn && readable(reinterpret_cast<void*>(fn), n) && memcmp(reinterpret_cast<void*>(fn), sig, n) == 0;
}

bool patch_slot(void** slot, void* hook) {
    DWORD old = 0;
    if (!VirtualProtect(slot, sizeof(void*), PAGE_READWRITE, &old)) return false;
    *slot = hook;
    VirtualProtect(slot, sizeof(void*), old, &old);
    return true;
}

void install_survival() {
    if (g_survival_hooked || g_survival_failed || !g_set_stamina || !g_set_health || !g_set_temp) return;
    auto vt_of = [](uintptr_t obj) -> void** {
        if (!readable(reinterpret_cast<void*>(obj), sizeof(void*))) return nullptr;
        auto vt = *reinterpret_cast<void***>(obj);
        return readable(vt, 200 * sizeof(void*)) ? vt : nullptr;
    };
    void** vs = vt_of(g_set_stamina);
    void** vh = vt_of(g_set_health);
    void** vtm = vt_of(g_set_temp);
    if (!vs || !vh || !vtm) return;  // objects not readable yet; Lua sends new ones
    // UAttributeSet_StaminaMetrics::PreGameplayEffectExecute prologue:
    // mov [rsp+8],rbx; mov [rsp+10h],rsi; push rdi; sub rsp,60h; mov rbx,[rdx+8]
    static const uint8_t stamina_sig[] = {0x48, 0x89, 0x5C, 0x24, 0x08, 0x48, 0x89, 0x74, 0x24, 0x10,
                                          0x57, 0x48, 0x83, 0xEC, 0x60, 0x48, 0x8B, 0x5A, 0x08};
    static const uint8_t base_sig[] = {0xB0, 0x01, 0xC3};  // mov al,1; ret
    int found = -1, matches = 0;
    for (int i = 0; i < 200; ++i) {
        auto s = reinterpret_cast<uintptr_t>(vs[i]);
        auto h = reinterpret_cast<uintptr_t>(vh[i]);
        if (h != reinterpret_cast<uintptr_t>(vtm[i])) continue;
        if (code_matches(s, stamina_sig, sizeof(stamina_sig)) && code_matches(h, base_sig, sizeof(base_sig))) {
            found = i;
            ++matches;
        }
    }
    if (matches != 1) {
        g_survival_failed = true;
        logf(L"survival rates OFF: PreGameplayEffectExecute slot found %d times (need 1); stats stay vanilla", matches);
        return;
    }
    g_pre_stamina = reinterpret_cast<PreExecFn>(vs[found]);
    g_pre_base = reinterpret_cast<PreExecFn>(vh[found]);
    bool ok = patch_slot(&vs[found], reinterpret_cast<void*>(&pre_stamina_hook));
    ok = ok && patch_slot(&vh[found], reinterpret_cast<void*>(&pre_base_hook));
    if (ok && vtm != vh) ok = patch_slot(&vtm[found], reinterpret_cast<void*>(&pre_base_hook));
    if (!ok) {
        // Put back whatever was changed.
        if (vs[found] == reinterpret_cast<void*>(&pre_stamina_hook)) patch_slot(&vs[found], reinterpret_cast<void*>(g_pre_stamina));
        if (vh[found] == reinterpret_cast<void*>(&pre_base_hook)) patch_slot(&vh[found], reinterpret_cast<void*>(g_pre_base));
        g_survival_failed = true;
        logf(L"survival rates OFF: vtable patch failed");
        return;
    }
    g_survival_hooked = true;
    logf(L"survival rates hooked (vtable slot %d of the Stamina, Health and Temperature sets)", found);
}

void read_survival() {
    std::wstring path = g_dir + L"survival.txt";
    WIN32_FILE_ATTRIBUTE_DATA attr{};
    if (!GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &attr)) return;
    if (CompareFileTime(&attr.ftLastWriteTime, &g_survival_time) == 0) {
        install_survival();
        return;
    }
    FILE* f = _wfopen(path.c_str(), L"rb");
    if (!f) return;
    char buf[1024] = {};
    size_t got = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    std::string text(buf, got);
    if (text.find("\nend\n") == std::string::npos) return;
    g_survival_time = attr.ftLastWriteTime;
    auto hex = [&](const char* key) -> uintptr_t {
        std::string k = std::string("\n") + key + "=";
        size_t at = ("\n" + text).find(k);
        if (at == std::string::npos) return 0;
        return static_cast<uintptr_t>(std::strtoull(text.c_str() + at + k.size() - 1, nullptr, 16));
    };
    g_survival_asc.store(hex("asc"));
    g_set_stamina = hex("stamina_set");
    g_set_health = hex("health_set");
    g_set_temp = hex("temperature_set");
    static const char* const keys[5] = {"stamina", "hunger", "energy", "health", "warmth"};
    for (int i = 0; i < 5; ++i) {
        std::string k = std::string("\n") + keys[i] + "=";
        size_t at = ("\n" + text).find(k);
        if (at == std::string::npos) continue;
        float m = static_cast<float>(std::strtod(text.c_str() + at + k.size() - 1, nullptr));
        if (m >= 0.0f && m <= 10.0f) {
            uint32_t bits;
            memcpy(&bits, &m, 4);
            g_surv_mult[i].store(bits);
        }
    }
    install_survival();
}

class Mod {
public:
    Mod() {
        ModName = L"Rebalance";
        ModVersion = L"1.3.0";
        ModDescription = L"Permafrost Overhaul native side: spawn blocker, headshots, toolbelt, survival rates, gunshot reverb, crafting from storage";
        ModAuthors = L"Permafrost Mods";
        ModIntendedSDKVersion = L"3.0.1";
    }
    virtual ~Mod() {
    }
    virtual void on_update() {
        tick();
    }
    virtual void on_unreal_init() {
        unreal_ready_ = 1;
    }
    virtual void v03() {}
    virtual void v04() {}
    virtual void v05() {}
    virtual void v06() {}
    virtual void v07() {}
    virtual void v08() {}
    virtual void v09() {}
    virtual void v10() {}
    virtual void v11() {}
    virtual void v12() {}
    virtual void v13() {}
    virtual void v14() {}
    virtual void v15() {}

private:
    void* gui_tabs_[3]{};  // +0x08 std::vector, owned by UE4SS
public:
    std::wstring ModName;                // +0x20
    std::wstring ModVersion;             // +0x40
    std::wstring ModDescription;         // +0x60
    std::wstring ModAuthors;             // +0x80
    std::wstring ModIntendedSDKVersion;  // +0xA0
private:
    uint64_t reserved_ = 0;              // +0xC0
    uint16_t unreal_ready_ = 0;          // +0xC8
};
static_assert(sizeof(Mod) == 0xD0, "CppUserModBase size");

}  // namespace

extern "C" __declspec(dllexport) Mod* start_mod() {
    InitializeCriticalSection(&g_log_lock);
    wchar_t self[MAX_PATH];
    HMODULE me = nullptr;
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                       reinterpret_cast<LPCWSTR>(&start_mod), &me);
    DWORD n = GetModuleFileNameW(me, self, MAX_PATH);
    if (n && n < MAX_PATH) {
        g_dir.assign(self, n);
        g_dir.erase(g_dir.find_last_of(L'\\') + 1);
        g_log = g_dir + L"main.log";
        DeleteFileW(g_log.c_str());
        // state.txt left from the last session holds that session's
        // addresses; wrapping them would write into random memory.
        DeleteFileW((g_dir + L"state.txt").c_str());
    }
    logf(L"started; waiting for Lua state");
    DeleteFileW((g_dir + L"spawnblock.txt").c_str());  // last session's addresses
    install_crash_report();
    install_spawn_blocker();
    DeleteFileW((g_dir + L"combat.txt").c_str());
    install_headshots();
    DeleteFileW((g_dir + L"animal_blocked.txt").c_str());  // last session's addresses
    install_animal_blocker();
    DeleteFileW((g_dir + L"travel.txt").c_str());
    DeleteFileW((g_dir + L"travel_paid.txt").c_str());
    install_travel_cost();
    DeleteFileW((g_dir + L"toolbelt.txt").c_str());
    install_toolbelt();
    DeleteFileW((g_dir + L"reverb.txt").c_str());
    InitializeCriticalSection(&g_rev_lock);
    install_reverb();
    DeleteFileW((g_dir + L"survival.txt").c_str());  // last session's addresses
    return new Mod();
}

extern "C" __declspec(dllexport) void uninstall_mod(Mod* mod) { delete mod; }

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) DisableThreadLibraryCalls(module);
    return TRUE;
}
