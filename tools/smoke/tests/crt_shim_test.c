/*
 * crt_shim_test.c — Wine smoke-test mod for src/crt_shim.c and src/crt_format.c.
 *
 * This is a Mewjector mod built exactly like the real one (zig, -nostdlib,
 * KERNEL32-only) but, instead of hooking the game, it drives the shim's
 * functions and reports each case through Mewjector's MJ_Log. Mewjector
 * formats the log with its own (real) CRT, so a bug in the shim can never
 * corrupt the pass/fail verdict itself.
 *
 * Build and run: tools/smoke/tests/run_crt_shim_test.sh (needs wine64).
 *
 * The test float/format expectations follow the MSVC semantics the mod needs
 * at runtime: snprintf returns the would-be length, %p is "0x" + lowercase
 * hex with "0" for NULL, and _snwprintf returns -1 on truncation while still
 * NUL-terminating. They are not glibc semantics (which uses %a/%e and round
 * half to even) because the shim stands in for the Windows CRT.
 */

#include <windows.h>
#include <stddef.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include "mewjector.h"

#define OWNER "CrtShimTest"
#define SCRATCH 256

static MewjectorAPI mj;
static int g_pass;
static int g_fail;

/* ------------------------------------------------------------------ report */

static void report(int ok, const char* label)
{
    if (ok)
    {
        g_pass++;
        mj.Log(OWNER, "PASS %s", label);
    }
    else
    {
        g_fail++;
        mj.Log(OWNER, "FAIL %s", label);
    }
}

/* ----------------------------------------------------------------- helpers */

/* Deliberately hand-written so a broken shim strcmp cannot mask a broken
 * snprintf: the comparison itself must not go through the code under test. */
static int same_text(const char* left, const char* right)
{
    size_t i = 0;
    while (left[i] != '\0' && right[i] != '\0')
    {
        if (left[i] != right[i]) return 0;
        i++;
    }
    return left[i] == '\0' && right[i] == '\0';
}

static int same_wide(const wchar_t* left, const wchar_t* right)
{
    size_t i = 0;
    while (left[i] != L'\0' && right[i] != L'\0')
    {
        if (left[i] != right[i]) return 0;
        i++;
    }
    return left[i] == L'\0' && right[i] == L'\0';
}

/* NULL through a function so -Wnonnull does not fire on the literal; the shim
 * explicitly accepts these as part of its contract. */
static const char* null_format(void) { return (const char*)0; }
static char* null_char_ptr(void) { return (char*)0; }
static const wchar_t* null_wide(void) { return (const wchar_t*)0; }
static wchar_t* null_wout(void) { return (wchar_t*)0; }
static void* null_void(void) { return (void*)0; }

static double make_inf(int negative)
{
    unsigned long long bits = negative ? 0xFFF0000000000000ULL : 0x7FF0000000000000ULL;
    double value = 0.0;
    memcpy(&value, &bits, sizeof value);
    return value;
}

static double make_nan(void)
{
    unsigned long long bits = 0x7FF8000000000000ULL;
    double value = 0.0;
    memcpy(&value, &bits, sizeof value);
    return value;
}

static size_t bounded_length(const char* text, size_t cap)
{
    size_t length = 0;
    while (length < cap && text[length] != '\0') length++;
    return length;
}

/* ------------------------------------------------------ narrow formatting */

static char out[SCRATCH];

static void fill_out(void)
{
    size_t i;
    for (i = 0; i < SCRATCH; i++) out[i] = (char)0xA5;
}

static int call_vsnprintf(char* buffer, size_t size, const char* format, ...)
{
    va_list args;
    int result;
    va_start(args, format);
    result = vsnprintf(buffer, size, format, args);
    va_end(args);
    return result;
}

static void report_narrow(const char* label, const char* expected, int expected_ret,
                          size_t size, int got)
{
    size_t i;
    int terminated = 0;
    int ok;

    if (size != 0)
    {
        for (i = 0; i < size && i < SCRATCH; i++)
        {
            if (out[i] == '\0') { terminated = 1; break; }
        }
    }
    ok = (got == expected_ret) && terminated && same_text(out, expected);
    report(ok, label);
    if (!ok)
    {
        mj.Log(OWNER, "  %s: got ret=%d want=%d len=%d",
               label, got, expected_ret, (int)bounded_length(out, size));
    }
}

#define CHECK_SNF(label, exp, ret, size, ...)                  \
    do {                                                       \
        int got_ = 0;                                          \
        fill_out();                                            \
        got_ = snprintf(out, (size), __VA_ARGS__);             \
        report_narrow((label), (exp), (ret), (size), got_);    \
    } while (0)

#define CHECK_VSNF(label, exp, ret, size, ...)                     \
    do {                                                           \
        int got_ = 0;                                              \
        fill_out();                                                \
        got_ = call_vsnprintf(out, (size), __VA_ARGS__);           \
        report_narrow((label), (exp), (ret), (size), got_);        \
    } while (0)

/* -------------------------------------------------------- wide formatting */

static wchar_t wout[SCRATCH];

static void fill_wout(void)
{
    size_t i;
    for (i = 0; i < SCRATCH; i++) wout[i] = (wchar_t)0xA5A5;
}

static void report_wide(const char* label, const wchar_t* expected, int expected_ret,
                        size_t count, int got)
{
    size_t i;
    int terminated = 0;
    int ok;

    if (count != 0)
    {
        for (i = 0; i < count && i < SCRATCH; i++)
        {
            if (wout[i] == L'\0') { terminated = 1; break; }
        }
    }
    ok = (got == expected_ret) && terminated && same_wide(wout, expected);
    report(ok, label);
    if (!ok)
    {
        mj.Log(OWNER, "  %s: got ret=%d want=%d", label, got, expected_ret);
    }
}

#define CHECK_WIDE(label, exp, ret, count, ...)                 \
    do {                                                        \
        int got_ = 0;                                           \
        fill_wout();                                            \
        got_ = _snwprintf(wout, (count), __VA_ARGS__);          \
        report_wide((label), (exp), (ret), (count), got_);      \
    } while (0)

/* -------------------------------------------------------------- test cases */

static void test_integers(void)
{
    CHECK_SNF("d zero", "0", 1, sizeof out, "%d", 0);
    CHECK_SNF("d positive", "42", 2, sizeof out, "%d", 42);
    CHECK_SNF("d negative", "-42", 3, sizeof out, "%d", -42);
    CHECK_SNF("i negative", "-7", 2, sizeof out, "%i", -7);
    CHECK_SNF("d INT_MAX", "2147483647", 10, sizeof out, "%d", 2147483647);
    CHECK_SNF("d INT_MIN", "-2147483648", 11, sizeof out, "%d", (-2147483647 - 1));
    CHECK_SNF("u zero", "0", 1, sizeof out, "%u", 0u);
    CHECK_SNF("u UINT_MAX", "4294967295", 10, sizeof out, "%u", 4294967295u);
    CHECK_SNF("llu max", "18446744073709551615", 20, sizeof out, "%llu",
              18446744073709551615ULL);
    CHECK_SNF("lld INT64_MIN", "-9223372036854775808", 20, sizeof out, "%lld",
              (-9223372036854775807LL - 1LL));
    CHECK_SNF("zu zero", "0", 1, sizeof out, "%zu", (size_t)0);
    CHECK_SNF("zu large", "1234567890", 10, sizeof out, "%zu", (size_t)1234567890);
    CHECK_SNF("zu SIZE_MAX", "18446744073709551615", 20, sizeof out, "%zu", (size_t)-1);
    CHECK_SNF("hhd truncates and signs", "-56", 3, sizeof out, "%hhd", 200);
    CHECK_SNF("hd truncates", "4464", 4, sizeof out, "%hd", 70000);
    CHECK_SNF("hhu truncates unsigned", "44", 2, sizeof out, "%hhu", 300);
    CHECK_SNF("hu truncates unsigned", "65535", 5, sizeof out, "%hu", 0x1FFFF);

    CHECK_SNF("x zero", "0", 1, sizeof out, "%x", 0u);
    CHECK_SNF("x lower", "ff", 2, sizeof out, "%x", 255u);
    CHECK_SNF("X upper", "FF", 2, sizeof out, "%X", 255u);
    CHECK_SNF("x wide value", "deadbeef", 8, sizeof out, "%x", 0xDEADBEEFu);
    CHECK_SNF("x of negative int", "ffffffff", 8, sizeof out, "%x", -1);
    CHECK_SNF("o octal", "10", 2, sizeof out, "%o", 8u);
    CHECK_SNF("o zero", "0", 1, sizeof out, "%o", 0u);
    CHECK_SNF("alt hex", "0xff", 4, sizeof out, "%#x", 255u);
    CHECK_SNF("alt HEX", "0XFF", 4, sizeof out, "%#X", 255u);
    CHECK_SNF("alt octal", "010", 3, sizeof out, "%#o", 8u);
    CHECK_SNF("alt hex zero has no prefix", "0", 1, sizeof out, "%#x", 0u);
    CHECK_SNF("alt hex zero-padded", "0x0000ff", 8, sizeof out, "%#08x", 255u);

    /* %zu is the size_t form MewUI's typed-text path would use on 64-bit. */
    CHECK_SNF("llu of size_t-width value", "1099511627776", 13, sizeof out, "%llu",
              (unsigned long long)((size_t)1 << 40));
}

/* GCC's printf checker does not know MSVC's %I/%I32/%I64 modifier: it reads
 * the I as the glibc "I" flag and then guesses the wrong argument types. The
 * tests below pass the width MSVC expects, so the warning is silenced here. */
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wformat"

/* MSVC's I length modifier: %I is size_t (pointer-sized), %I32 a 32-bit
 * value, %I64 a 64-bit one, in every integer conversion. The patched
 * Mewjector loader writes pointer-sized values with %IX (and _snprintf), so
 * the mixed case below is the regression guard: a formatter that copied 
 * "%I" literally would never consume the size_t argument and the %d and %p
 * that follow would read the wrong ones. */
static void test_i_length_modifier(void)
{
    /* Bare I is size_t, i.e. 8 bytes on this 64-bit target. */
    CHECK_SNF("I u max", "18446744073709551615", 20, sizeof out, "%Iu",
              (unsigned long long)-1);
    CHECK_SNF("I u zero", "0", 1, sizeof out, "%Iu", (unsigned long long)0);
    CHECK_SNF("I d positive", "42", 2, sizeof out, "%Id", (long long)42);
    CHECK_SNF("I d negative", "-42", 3, sizeof out, "%Id", (long long)-42);
    CHECK_SNF("I x", "deadbeef", 8, sizeof out, "%Ix", (unsigned long long)0xDEADBEEFu);
    CHECK_SNF("I X", "DEADBEEF", 8, sizeof out, "%IX", (unsigned long long)0xDEADBEEFu);
    CHECK_SNF("I o", "10", 2, sizeof out, "%Io", (unsigned long long)8);

    /* I32 is a 32-bit value, so UINT_MAX must not be sign-extended. */
    CHECK_SNF("I32 d", "42", 2, sizeof out, "%I32d", (long)42);
    CHECK_SNF("I32 d negative", "-42", 3, sizeof out, "%I32d", (long)-42);
    CHECK_SNF("I32 u max", "4294967295", 10, sizeof out, "%I32u", (unsigned long)0xFFFFFFFFu);
    CHECK_SNF("I32 x", "deadbeef", 8, sizeof out, "%I32x", (unsigned long)0xDEADBEEFu);
    CHECK_SNF("I32 X", "DEADBEEF", 8, sizeof out, "%I32X", (unsigned long)0xDEADBEEFu);
    CHECK_SNF("I32 o max", "37777777777", 11, sizeof out, "%I32o", (unsigned long)0xFFFFFFFFu);

    /* I64 is a 64-bit value, so the high word must be read. */
    CHECK_SNF("I64 d min", "-9223372036854775808", 20, sizeof out, "%I64d",
              (long long)(-9223372036854775807LL - 1LL));
    CHECK_SNF("I64 u max", "18446744073709551615", 20, sizeof out, "%I64u",
              (unsigned long long)-1);
    CHECK_SNF("I64 x", "deadbeefcafebabe", 16, sizeof out, "%I64x",
              (unsigned long long)0xDEADBEEFCAFEBABEULL);
    CHECK_SNF("I64 X", "DEADBEEFCAFEBABE", 16, sizeof out, "%I64X",
              (unsigned long long)0xDEADBEEFCAFEBABEULL);
    CHECK_SNF("I64 o max", "1777777777777777777777", 22, sizeof out, "%I64o",
              (unsigned long long)-1);

    /* Flags and width apply to the I forms like any other length. */
    CHECK_SNF("I zero pad", "0000000000001234", 16, sizeof out, "%016IX",
              (unsigned long long)0x1234u);
    CHECK_SNF("I32 zero pad", "000000ab", 8, sizeof out, "%08I32x", (unsigned long)0xABu);
    CHECK_SNF("I64 zero pad", "00000000000000FF", 16, sizeof out, "%016I64X",
              (unsigned long long)0xFFu);
    CHECK_SNF("I32 plus flag", "+42", 3, sizeof out, "%+I32d", (long)42);
    CHECK_SNF("I64 plus flag", "+42", 3, sizeof out, "%+I64d", (long long)42);
    CHECK_SNF("I32 plus negative keeps sign", "-7", 2, sizeof out, "%+I32d", (long)-7);
    CHECK_SNF("I alt hex zero pad", "0x00000012", 10, sizeof out, "%#010I32x",
              (unsigned long)0x12u);

    /* The loader's crash line shape: %IX between a %d and a %p, so every
     * argument is consumed exactly once and in order. This is the regression
     * for the pre-fix bug where %IX printed literally and desynchronised the
     * following arguments. (%p here already emits its own "0x" prefix, so the
     * format does not add a second one.) */
    CHECK_SNF("mixed IX does not consume the next argument",
              "site[1] RVA=0x1234  patchAddr=0x5678  stolen=2", 46, sizeof out,
              "site[%d] RVA=0x%IX  patchAddr=%p  stolen=%d",
              1, (unsigned long long)0x1234u, (void*)0x5678, 2);
    CHECK_SNF("mixed I32X does not consume the next argument",
              "0x1234 -7 0x42", 14, sizeof out, "0x%I32X %d 0x%IX",
              (unsigned long)0x1234u, -7, (unsigned long long)0x42u);
}

#pragma GCC diagnostic pop

static void test_pointers(void)
{
    CHECK_SNF("p NULL", "0", 1, sizeof out, "%p", (void*)0);
    CHECK_SNF("p nonzero", "0x1234", 6, sizeof out, "%p", (void*)0x1234);
    CHECK_SNF("p high value", "0xdeadbeef", 10, sizeof out, "%p", (void*)0xDEADBEEF);
    CHECK_SNF("p padded", " 0x1234", 7, sizeof out, "%7p", (void*)0x1234);
}

static void test_strings(void)
{
    CHECK_SNF("s plain", "abc", 3, sizeof out, "%s", "abc");
    CHECK_SNF("s empty", "", 0, sizeof out, "%s", "");
    CHECK_SNF("s NULL", "(null)", 6, sizeof out, "%s", (const char*)0);
    CHECK_SNF("s width right", "       abc", 10, sizeof out, "%10s", "abc");
    CHECK_SNF("s width left", "abc       ", 10, sizeof out, "%-10s", "abc");
    CHECK_SNF("s precision", "ab", 2, sizeof out, "%.2s", "abcdef");
    CHECK_SNF("s width and precision", "   ab", 5, sizeof out, "%5.2s", "abcdef");
    CHECK_SNF("s NULL precision", "(nu", 3, sizeof out, "%.3s", (const char*)0);
    CHECK_SNF("c plain", "A", 1, sizeof out, "%c", 'A');
    CHECK_SNF("c in width", "   Z", 4, sizeof out, "%4c", 'Z');
    CHECK_SNF("percent only", "%", 1, sizeof out, "%%");
    CHECK_SNF("percent in text", "a%b", 3, sizeof out, "a%%b");
    CHECK_SNF("literal only", "hello", 5, sizeof out, "hello");
    CHECK_SNF("empty format", "", 0, sizeof out, "");
    CHECK_SNF("MewUI state name", "on_state", 8, sizeof out, "%s%s", "on_", "state");
    CHECK_SNF("MewUI label path", "foo.label", 9, sizeof out, "%s.label", "foo");
    {
        char malformed[8];
        int got;
        malformed[0] = 'a'; malformed[1] = 'b'; malformed[2] = 'c';
        malformed[3] = '%'; malformed[4] = '\0';
        fill_out();
        got = snprintf(out, sizeof out, malformed, 0);
        report_narrow("malformed trailing percent", "abc%", 4, sizeof out, got);
    }
}

static void test_width_precision_and_truncation(void)
{
    CHECK_SNF("zero pad d", "00000042", 8, sizeof out, "%08d", 42);
    CHECK_SNF("zero pad negative keeps sign first", "-00042", 6, sizeof out, "%06d", -42);
    CHECK_SNF("plus flag", "+42", 3, sizeof out, "%+d", 42);
    CHECK_SNF("space flag", " 42", 3, sizeof out, "% d", 42);
    CHECK_SNF("space flag ignored for negative", "-42", 3, sizeof out, "% d", -42);
    CHECK_SNF("width right", "    42", 6, sizeof out, "%6d", 42);
    CHECK_SNF("width left", "42    ", 6, sizeof out, "%-6d", 42);
    CHECK_SNF("precision pads d", "00042", 5, sizeof out, "%.5d", 42);
    CHECK_SNF("precision with plus", "+042", 4, sizeof out, "%+.3d", 42);
    CHECK_SNF("precision pads x", "00ff", 4, sizeof out, "%.4x", 255u);
    CHECK_SNF("precision zero drops s", "", 0, sizeof out, "%.0s", "abc");
    CHECK_SNF("alt octal zero has no prefix", "0", 1, sizeof out, "%#o", 0u);
    CHECK_SNF("precision zero drops d zero", "", 0, sizeof out, "%.0d", 0);
    CHECK_SNF("precision with negative", "-042", 4, sizeof out, "%.3d", -42);
    CHECK_SNF("precision overrides zero flag", "     042", 8, sizeof out, "%08.3d", 42);
    CHECK_SNF("star width", "    42", 6, sizeof out, "%*d", 6, 42);
    CHECK_SNF("negative star width is left", "42    ", 6, sizeof out, "%*d", -6, 42);
    CHECK_SNF("star precision", "0042", 4, sizeof out, "%.*d", 4, 42);

    /* Truncation: the return value is the would-be length, the buffer holds
     * min(length, size-1) characters and is always NUL-terminated. */
    CHECK_SNF("truncate d", "123", 5, 4, "%d", 12345);
    CHECK_SNF("truncate s keeps prefix", "hel", 5, 4, "%s", "hello");
    CHECK_SNF("truncate to one byte", "", 5, 1, "%s", "hello");
    {
        /* width 200 leaves 199 spaces then '5'; size 20 keeps 19 bytes. */
        char expected[20];
        int got;
        size_t i;
        for (i = 0; i < 19; i++) expected[i] = ' ';
        expected[19] = '\0';
        fill_out();
        got = snprintf(out, 20, "%200d", 5);
        report_narrow("truncate wide padding", expected, 200, 20, got);
    }

    {
        char tiny[1];
        int got;
        tiny[0] = (char)0x5A;
        got = snprintf(tiny, 1, "%s", "hello");
        report(got == 5 && tiny[0] == '\0', "size 1 writes only the terminator");
    }
    {
        char untouched[4];
        int i;
        int got;
        for (i = 0; i < 4; i++) untouched[i] = (char)0x5A;
        got = snprintf(untouched, 0, "%s", "hello");
        report(got == 5 && untouched[0] == (char)0x5A && untouched[3] == (char)0x5A,
               "size 0 writes nothing but returns would-be length");
    }
    {
        int got = snprintf(null_char_ptr(), 0, "%s", "hello");
        report(got == 5, "NULL buffer with size 0 returns would-be length");
    }
    {
        int got = snprintf(null_char_ptr(), 0, "%s", (const char*)0);
        report(got == 6, "NULL buffer accepts NULL %%s as (null)");
    }
    {
        char buffer[8];
        int got;
        buffer[0] = (char)0x5A;
        got = snprintf(buffer, sizeof buffer, null_format(), 0);
        report(got == -1 && buffer[0] == '\0', "NULL format returns -1 and empties buffer");
    }
}

static void test_floats(void)
{
    /* The exact MewUI call pattern: "%.3f" in the audio/seek log line and the
     * L"%%.%uf" two-step build used by the typed-text path. */
    CHECK_SNF("f default precision", "1.000000", 8, sizeof out, "%f", 1.0);
    CHECK_SNF("f 3dp", "1.500", 5, sizeof out, "%.3f", 1.5);
    CHECK_SNF("f zero", "0.000", 5, sizeof out, "%.3f", 0.0);
    {
        /* -0.0 has the sign bit set; MSVC and glibc both keep the minus.
         * The shim tests `value < 0.0`, which is false for negative zero. */
        int got;
        fill_out();
        got = snprintf(out, sizeof out, "%.3f", -0.0);
        if (!(got == 6 && same_text(out, "-0.000")))
        {
            mj.Log(OWNER, "  negative zero produced '%s' (ret=%d)", out, got);
        }
        report(got == 6 && same_text(out, "-0.000"),
               "f negative zero keeps the sign");
    }
    CHECK_SNF("f negative", "-0.500", 6, sizeof out, "%.3f", -0.5);
    CHECK_SNF("f rounds up", "0.13", 4, sizeof out, "%.2f", 0.125);
    CHECK_SNF("f rounds integer", "3", 1, sizeof out, "%.0f", 2.5);
    CHECK_SNF("f integral value", "123.456", 7, sizeof out, "%.3f", 123.456);
    CHECK_SNF("f plus flag", "+3.50", 5, sizeof out, "%+.2f", 3.5);
    CHECK_SNF("f space flag", " 3.50", 5, sizeof out, "% .2f", 3.5);
    CHECK_SNF("f width right", "    3.50", 8, sizeof out, "%8.2f", 3.5);
    CHECK_SNF("f width left", "3.50    ", 8, sizeof out, "%-8.2f", 3.5);
    CHECK_SNF("f zero pad keeps sign first", "-0003.50", 8, sizeof out, "%08.2f", -3.5);
    CHECK_SNF("f zero pad", "00003.50", 8, sizeof out, "%08.2f", 3.5);

    /* Beyond 2^64/10^precision the integer part walks digits directly; it must
     * still be finite, exact for the integer and padded with zero fraction. */
    CHECK_SNF("f huge integer part", "100000000000000000000", 21, sizeof out,
              "%.0f", 1e20);
    CHECK_SNF("f huge with fraction", "100000000000000000000.000", 25, sizeof out,
              "%.3f", 1e20);

    CHECK_SNF("f nan", "nan", 3, sizeof out, "%f", make_nan());
    CHECK_SNF("f positive inf", "inf", 3, sizeof out, "%f", make_inf(0));
    CHECK_SNF("f negative inf", "-inf", 4, sizeof out, "%f", make_inf(1));
    CHECK_SNF("f plus inf", "+inf", 4, sizeof out, "%+f", make_inf(0));

    /* %e/%g/%a are accepted (MewUI never asks for a different rendering). */
    CHECK_SNF("e accepted as fixed", "1.500000", 8, sizeof out, "%e", 1.5);
    CHECK_SNF("g accepted as fixed", "1.500000", 8, sizeof out, "%g", 1.5);
}

static void test_vsnprintf(void)
{
    /* vsnprintf is the shared implementation; exercise it directly too. */
    CHECK_VSNF("vsnprintf d", "42", 2, sizeof out, "%d", 42);
    CHECK_VSNF("vsnprintf mixed", "x=-7 s=hi", 9, sizeof out, "x=%d s=%s", -7, "hi");
    CHECK_VSNF("vsnprintf truncation", "12", 5, 3, "%d", 12345);
}

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wformat"

/* _snprintf is the MSVC spelling the loader's crash writer calls. The shim
 * returns the would-be length (the caller clamps it) and always terminates. */
static void test_snprintf_msvc(void)
{
    {
        char buffer[64];
        int got;
        buffer[0] = (char)0x5A;
        got = _snprintf(buffer, sizeof buffer, "%IX", (unsigned long long)0xDEADBEEFu);
        report(got == 8 && same_text(buffer, "DEADBEEF"),
               "_snprintf formats the loader's %IX");
    }
    {
        char buffer[6];
        int got;
        size_t i;
        for (i = 0; i < sizeof buffer; i++) buffer[i] = (char)0x5A;
        got = _snprintf(buffer, sizeof buffer, "0x%IX", (unsigned long long)0xDEADBEEFu);
        report(got == 10 && same_text(buffer, "0xDEA"),
               "_snprintf truncates %IX and NUL-terminates");
    }
    {
        char buffer[64];
        int got;
        got = _snprintf(buffer, sizeof buffer, "site[%d] RVA=0x%IX", 2,
                        (unsigned long long)0xBEEFu);
        report(got == 18 && same_text(buffer, "site[2] RVA=0xBEEF"),
               "_snprintf mixed %%d then %%IX consumes both arguments");
    }
}

#pragma GCC diagnostic pop

static void test_snwprintf(void)
{
    CHECK_WIDE("wide d", L"42", 2, 16, L"%d", 42);
    CHECK_WIDE("wide d negative", L"-42", 3, 16, L"%d", -42);
    CHECK_WIDE("wide u", L"4294967295", 10, 16, L"%u", 4294967295u);
    CHECK_WIDE("wide exact fit", L"42", 2, 3, L"%d", 42);
    CHECK_WIDE("wide percent", L"%d", 2, 16, L"%%d");

    /* The typed-text path builds its own format string first. */
    CHECK_WIDE("wide build format", L"%.3f", 4, 16, L"%%.%uf", 3u);
    {
        wchar_t format[16];
        int got_format;
        int got_value;
        fill_wout();
        got_format = _snwprintf(format, 16, L"%%.%uf", 2u);
        fill_wout();
        got_value = _snwprintf(wout, 16, format, 1.5);
        report(got_format == 4 && got_value == 4 && same_wide(wout, L"1.50"),
               "wide typed-text two-step build and format");
    }

    /* MSVC _snwprintf return: -1 when the result does not fit, buffer still
     * NUL-terminated after min(count-1, length) characters. */
    {
        int got;
        fill_wout();
        got = _snwprintf(wout, 4, L"%u", 4294967295u);
        report(got == -1 && same_wide(wout, L"429"),
               "wide truncation returns -1 and keeps prefix");
    }
    {
        int got = _snwprintf(null_wout(), 0, L"%d", 1);
        report(got == -1, "wide count 0 returns -1");
    }
    {
        int got = _snwprintf(null_wout(), 16, L"%d", 1);
        report(got == -1, "wide NULL buffer returns -1");
    }
    {
        int got = _snwprintf(wout, 16, null_wide());
        report(got == -1, "wide NULL format returns -1");
    }
    {
        int got = _snwprintf(wout, 16, L"%d", 1);
        report(got == 1, "wide d one digit");
    }
}

static void test_memory(void)
{
    {
        char buffer[8];
        char* result;
        size_t i;
        int ok = 1;
        for (i = 0; i < 8; i++) buffer[i] = 0;
        result = (char*)memset(buffer, 0x7F, 8);
        for (i = 0; i < 8; i++) if ((unsigned char)buffer[i] != 0x7F) ok = 0;
        report(result == buffer && ok, "memset fills and returns destination");
    }
    {
        char buffer[4];
        size_t i;
        for (i = 0; i < 4; i++) buffer[i] = (char)0x33;
        report(memset(buffer, 0, 0) == buffer && (unsigned char)buffer[0] == 0x33,
               "memset count 0 leaves memory untouched");
        report(memset(null_void(), 0, 0) == null_void(), "memset NULL/0 is a safe no-op");
    }
    {
        char source[5] = { 'a', 'b', 'c', 'd', 'e' };
        char destination[6];
        size_t i;
        for (i = 0; i < 6; i++) destination[i] = (char)0x11;
        report(memcpy(destination, source, 5) == destination &&
                   destination[0] == 'a' && destination[1] == 'b' &&
                   destination[2] == 'c' && destination[3] == 'd' &&
                   destination[4] == 'e' && destination[5] == (char)0x11,
               "memcpy copies and returns destination");
    }
    {
        char destination[1];
        destination[0] = (char)0x77;
        report(memcpy(destination, null_void(), 0) == destination &&
                   destination[0] == (char)0x77,
               "memcpy count 0 returns destination");
    }
    {
        char high = (char)0x80;
        char low = (char)0x01;
        report(memcmp("abc", "abc", 3) == 0, "memcmp equal is 0");
        report(memcmp("abc", "abd", 3) < 0, "memcmp smaller is negative");
        report(memcmp("abd", "abc", 3) > 0, "memcmp larger is positive");
        report(memcmp("abc", "abd", 0) == 0, "memcmp count 0 is 0");
        report(memcmp(&high, &low, 1) > 0, "memcmp compares bytes unsigned");
    }
}

static void test_string_helpers(void)
{
    report(strlen("") == 0, "strlen empty is 0");
    report(strlen("abc") == 3, "strlen counts characters");
    report(strlen(null_format()) == 0, "strlen NULL is 0");

    report(strcmp("abc", "abc") == 0, "strcmp equal is 0");
    report(strcmp("abc", "abd") < 0, "strcmp smaller is negative");
    report(strcmp("abd", "abc") > 0, "strcmp larger is positive");
    report(strcmp("", "a") < 0, "strcmp empty is smaller");

    {
        char destination[8];
        char* result;
        size_t i;
        for (i = 0; i < 8; i++) destination[i] = (char)0x55;
        result = strncpy(destination, "abcdef", 3);
        report(result == destination && destination[0] == 'a' &&
                   destination[1] == 'b' && destination[2] == 'c' &&
                   destination[3] == (char)0x55,
               "strncpy copies count bytes without terminating");
    }
    {
        char destination[8];
        char* result;
        size_t i;
        for (i = 0; i < 8; i++) destination[i] = (char)0x55;
        result = strncpy(destination, "ab", 6);
        report(result == destination && destination[0] == 'a' &&
                   destination[1] == 'b' && destination[2] == '\0' &&
                   destination[3] == '\0' && destination[4] == '\0' &&
                   destination[5] == '\0' && destination[6] == (char)0x55,
               "strncpy pads the remainder with NUL");
    }
    {
        char destination[4];
        size_t i;
        for (i = 0; i < 4; i++) destination[i] = (char)0x55;
        strncpy(destination, "abc", 0);
        report(destination[0] == (char)0x55 && destination[3] == (char)0x55,
               "strncpy count 0 leaves destination untouched");
    }
    {
        char destination[4];
        destination[0] = (char)0x55;
        report(strncpy(destination, null_format(), 4) == destination &&
                   destination[0] == '\0',
               "strncpy NULL source writes an empty string");
    }

    report(wcslen(L"") == 0, "wcslen empty is 0");
    report(wcslen(L"abc") == 3, "wcslen counts wide characters");
    report(wcslen(L"\u00e9\u4e2d") == 2, "wcslen counts UTF-16 code units");
    report(wcslen(null_wide()) == 0, "wcslen NULL is 0");
}

static void test_heap(void)
{
    {
        unsigned char* block = (unsigned char*)malloc(16);
        int ok = (block != 0);
        int i;
        if (ok)
        {
            for (i = 0; i < 16; i++) block[i] = (unsigned char)(i * 7 + 3);
            for (i = 0; i < 16; i++)
            {
                if (block[i] != (unsigned char)(i * 7 + 3)) ok = 0;
            }
            free(block);
        }
        report(ok, "malloc allocates writable memory");
    }
    {
        void* block = malloc(0);
        report(block != 0, "malloc(0) returns a freeable pointer");
        free(block);
    }
    {
        unsigned char* block = (unsigned char*)calloc(4, 8);
        int ok = (block != 0);
        int i;
        if (ok)
        {
            for (i = 0; i < 32; i++) if (block[i] != 0) ok = 0;
            for (i = 0; i < 32; i++) block[i] = (unsigned char)(i + 1);
            for (i = 0; i < 32; i++)
            {
                if (block[i] != (unsigned char)(i + 1)) ok = 0;
            }
            free(block);
        }
        report(ok, "calloc zeroes and is writable");
    }
    {
        void* block = calloc(0, 8);
        report(block != 0, "calloc(0, n) returns a freeable pointer");
        free(block);
    }
    report(calloc((size_t)-1, 2) == 0, "calloc overflow guard returns NULL");
    report(calloc((size_t)-1, (size_t)-1) == 0, "calloc max/max returns NULL");
    report(malloc((size_t)-1) == 0, "malloc SIZE_MAX fails cleanly");
    {
        size_t big = (size_t)1 << 20;
        unsigned char* block = (unsigned char*)malloc(big);
        int ok = (block != 0);
        if (ok)
        {
            block[0] = 0x11;
            block[big - 1U] = 0x22;
            ok = (block[0] == 0x11 && block[big - 1U] == 0x22);
            free(block);
        }
        report(ok, "malloc 1 MiB is writable at both ends");
    }
    free(null_void());
    report(1, "free(NULL) is safe");
}

static void run_tests(void)
{
    test_integers();
    test_i_length_modifier();
    test_pointers();
    test_strings();
    test_width_precision_and_truncation();
    test_floats();
    test_vsnprintf();
    test_snprintf_msvc();
    test_snwprintf();
    test_memory();
    test_string_helpers();
    test_heap();
}

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID reserved)
{
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH)
    {
        DisableThreadLibraryCalls(module);
        if (!MJ_Require(OWNER) || !MJ_Resolve(&mj))
        {
            OutputDebugStringA("CrtShimTest: Mewjector API unavailable\n");
            return TRUE;
        }
        mj.Log(OWNER, "START shim test");
        run_tests();
        mj.Log(OWNER, "DONE pass=%d fail=%d", g_pass, g_fail);
    }
    return TRUE;
}
