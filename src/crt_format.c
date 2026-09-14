/*
 * crt_format.c — the snprintf/vsnprintf/_snwprintf half of the CRT shim.
 *
 * Split out of src/crt_shim.c so neither file passes the project's size
 * budget. crt_shim.c holds the memory/string/heap replacements and explains
 * why the shim exists at all (a KERNEL32-only DLL; see build.sh rule 2).
 *
 * Coverage: the specifiers MewUI actually passes (%s %c %d %i %u %x %X %o %p
 * %zu %llu %f and %%), the usual flags, width and precision (including the
 * "%.3f" in MewUI's seek/audio log line and the "%.Nf" its typed-text path
 * builds with _snwprintf), plus the length modifiers hh/h/l/ll/z/j/t/L and
 * MSVC's I size_t modifier (%I, %I32, %I64). The I forms matter because the
 * patched Mewjector loader's log and crash lines use %IX for pointer-sized
 * values; without them the specifier is copied literally and its argument is
 * never consumed, so every later argument reads the wrong one.
 * `%e`/`%g`/`%a` are accepted but rendered as fixed-point, which is all MewUI
 * asks for. The float path is exact for |v| below 2^64 / 10^precision and
 * falls back to direct integer-digit extraction above that, so it never
 * overflows or traps. Built with -ffreestanding -fno-builtin.
 */

#include <stddef.h>
#include <stdarg.h>
#include <windows.h>

#define MEW_CRT_DIGITS_MAX 32
#define MEW_CRT_FLOAT_SCRATCH 512
#define MEW_CRT_FORMAT_SCRATCH 128
#define MEW_CRT_FLOAT_PRECISION_MAX 18
#define MEW_CRT_DEFAULT_FLOAT_PRECISION 6
#define MEW_CRT_ROUND_HALF 0.5
#define MEW_CRT_ASCII_MAX 0x80

/* 2^64: a double at or above this cannot convert to uint64 exactly. The slack
 * keeps (scaled + 0.5) safely below the limit before the cast. */
static const double MEW_CRT_U64_LIMIT = 18446744073709551616.0;
static const double MEW_CRT_U64_ROUNDING_SLACK = 2048.0;

typedef struct MewCrtSink
{
    char* buffer;
    size_t size;
    size_t count;
} MewCrtSink;

typedef struct MewCrtSpec
{
    int left;
    int zero;
    int plus;
    int space;
    int alt;
    int width;
    int precision;
} MewCrtSpec;

static void MewCrtPut(MewCrtSink* sink, char ch)
{
    /* The last byte is reserved for the terminator. */
    if (sink->size != 0 && sink->count + 1 < sink->size)
    {
        sink->buffer[sink->count] = ch;
    }
    sink->count++;
}

static void MewCrtRepeat(MewCrtSink* sink, char ch, size_t count)
{
    while (count-- != 0)
    {
        MewCrtPut(sink, ch);
    }
}

static size_t MewCrtUnsignedDigits(char* out, unsigned long long value, unsigned base, int upper)
{
    const char* set = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    char reversed[MEW_CRT_DIGITS_MAX];
    size_t length = 0;
    size_t i;

    if (value == 0)
    {
        out[0] = '0';
        return 1;
    }

    while (value != 0 && length < MEW_CRT_DIGITS_MAX)
    {
        reversed[length++] = set[(unsigned)(value % base)];
        value /= base;
    }

    for (i = 0; i < length; i++)
    {
        out[i] = reversed[length - 1U - i];
    }
    return length;
}

/* Fixed-point text for a non-negative finite double. `out` must hold at least
 * MEW_CRT_FLOAT_SCRATCH bytes. */
static size_t MewCrtFixedDouble(char* out, double value, unsigned precision)
{
    char digits[MEW_CRT_DIGITS_MAX];
    unsigned long long scale = 1ULL;
    unsigned long long total;
    unsigned long long integer_part;
    unsigned long long fraction_part;
    size_t integer_length;
    size_t length = 0;
    unsigned i;

    if (precision > MEW_CRT_FLOAT_PRECISION_MAX)
    {
        precision = MEW_CRT_FLOAT_PRECISION_MAX;
    }

    for (i = 0; i < precision; i++)
    {
        scale *= 10ULL;
    }

    if (value * (double)scale < MEW_CRT_U64_LIMIT - MEW_CRT_U64_ROUNDING_SLACK)
    {
        total = (unsigned long long)(value * (double)scale + MEW_CRT_ROUND_HALF);
        integer_part = total / scale;
        fraction_part = total % scale;
    }
    else
    {
        /* Beyond uint64: walk the integer digits directly; doubles there have
         * no meaningful fraction left, so the fraction is zeros. */
        double step = 1.0;
        double rest = value;

        while (step <= rest / 10.0)
        {
            step *= 10.0;
        }
        while (step >= 1.0 && length < MEW_CRT_FLOAT_SCRATCH - 2U)
        {
            int digit = (int)(rest / step);
            if (digit < 0)
            {
                digit = 0;
            }
            if (digit > 9)
            {
                digit = 9;
            }
            out[length++] = (char)('0' + digit);
            rest -= (double)digit * step;
            step /= 10.0;
        }
        if (precision == 0U)
        {
            return length;
        }
        out[length++] = '.';
        for (i = 0; i < precision; i++)
        {
            out[length++] = '0';
        }
        return length;
    }

    integer_length = MewCrtUnsignedDigits(digits, integer_part, 10U, 0);
    for (i = 0; i < (unsigned)integer_length; i++)
    {
        out[length++] = digits[i];
    }

    if (precision != 0U)
    {
        out[length++] = '.';
        for (i = 0; i < precision; i++)
        {
            digits[i] = (char)('0' + (int)(fraction_part % 10ULL));
            fraction_part /= 10ULL;
        }
        for (i = 0; i < precision; i++)
        {
            out[length++] = digits[precision - 1U - i];
        }
    }
    return length;
}

static void MewCrtEmitNumber(MewCrtSink* sink, const MewCrtSpec* spec,
                             unsigned long long magnitude, int negative, int signed_value,
                             unsigned base, int upper, int pointer)
{
    char digits[MEW_CRT_DIGITS_MAX];
    char prefix[4];
    size_t digit_length;
    size_t prefix_length = 0;
    size_t zero_count = 0;
    size_t total;
    size_t padding;
    size_t i;

    digit_length = MewCrtUnsignedDigits(digits, magnitude, base, upper);
    if (spec->precision == 0 && magnitude == 0)
    {
        digit_length = 0;
    }
    if (spec->precision > 0 && (size_t)spec->precision > digit_length)
    {
        zero_count = (size_t)spec->precision - digit_length;
    }

    if (signed_value && negative)
    {
        prefix[prefix_length++] = '-';
    }
    else if (signed_value && spec->plus)
    {
        prefix[prefix_length++] = '+';
    }
    else if (signed_value && spec->space)
    {
        prefix[prefix_length++] = ' ';
    }

    if (pointer && magnitude != 0)
    {
        prefix[prefix_length++] = '0';
        prefix[prefix_length++] = 'x';
    }
    else if (spec->alt && base == 16U && magnitude != 0)
    {
        prefix[prefix_length++] = '0';
        prefix[prefix_length++] = upper ? 'X' : 'x';
    }
    else if (spec->alt && base == 8U && (digit_length == 0 || digits[0] != '0'))
    {
        prefix[prefix_length++] = '0';
    }

    total = prefix_length + zero_count + digit_length;
    padding = (spec->width > 0 && (size_t)spec->width > total)
                  ? (size_t)spec->width - total : 0;

    if (spec->left)
    {
        for (i = 0; i < prefix_length; i++) MewCrtPut(sink, prefix[i]);
        MewCrtRepeat(sink, '0', zero_count);
        for (i = 0; i < digit_length; i++) MewCrtPut(sink, digits[i]);
        MewCrtRepeat(sink, ' ', padding);
    }
    else if (spec->zero && spec->precision < 0)
    {
        for (i = 0; i < prefix_length; i++) MewCrtPut(sink, prefix[i]);
        MewCrtRepeat(sink, '0', padding);
        MewCrtRepeat(sink, '0', zero_count);
        for (i = 0; i < digit_length; i++) MewCrtPut(sink, digits[i]);
    }
    else
    {
        MewCrtRepeat(sink, ' ', padding);
        for (i = 0; i < prefix_length; i++) MewCrtPut(sink, prefix[i]);
        MewCrtRepeat(sink, '0', zero_count);
        for (i = 0; i < digit_length; i++) MewCrtPut(sink, digits[i]);
    }
}

static void MewCrtEmitText(MewCrtSink* sink, const MewCrtSpec* spec,
                           const char* text, size_t length)
{
    size_t padding;
    size_t i;

    if (spec->precision >= 0 && (size_t)spec->precision < length)
    {
        length = (size_t)spec->precision;
    }
    padding = (spec->width > 0 && (size_t)spec->width > length)
                  ? (size_t)spec->width - length : 0;

    if (!spec->left)
    {
        MewCrtRepeat(sink, ' ', padding);
    }
    for (i = 0; i < length; i++)
    {
        MewCrtPut(sink, text[i]);
    }
    if (spec->left)
    {
        MewCrtRepeat(sink, ' ', padding);
    }
}

/* The sign comes from the sign bit, not from `value < 0.0`: an ordered
 * comparison is false for negative zero, which the CRT still prints as
 * "-0.000". NaN is filtered out by the caller before this is used. */
static int MewCrtIsNegative(double value)
{
    union
    {
        double number;
        unsigned long long bits;
    } pun;

    pun.number = value;
    return (pun.bits >> 63) != 0ULL;
}

/* inf/nan: the sign is emitted separately from the "inf"/"nan" body so the
 * precision, which only describes the digits of a finite value, cannot cut it
 * short ("%.2f" of -inf must stay "-inf", not "-in"). */
static void MewCrtEmitSpecialFloat(MewCrtSink* sink, const MewCrtSpec* spec,
                                   const char* body, size_t length, int negative)
{
    char text[4];
    size_t text_length = 0;
    size_t i;
    MewCrtSpec text_spec = *spec;

    if (negative)
    {
        text[text_length++] = '-';
    }
    else if (spec->plus)
    {
        text[text_length++] = '+';
    }
    else if (spec->space)
    {
        text[text_length++] = ' ';
    }
    for (i = 0; i < length && text_length < sizeof text; i++)
    {
        text[text_length++] = body[i];
    }

    text_spec.precision = -1;
    MewCrtEmitText(sink, &text_spec, text, text_length);
}

static void MewCrtEmitFloat(MewCrtSink* sink, const MewCrtSpec* spec, double value)
{
    char body[MEW_CRT_FLOAT_SCRATCH];
    size_t length;
    size_t padding;
    size_t i;
    unsigned precision = spec->precision < 0
                             ? MEW_CRT_DEFAULT_FLOAT_PRECISION
                             : (unsigned)spec->precision;
    char sign = '\0';

    if (value != value)
    {
        MewCrtEmitSpecialFloat(sink, spec, "nan", 3U, MewCrtIsNegative(value));
        return;
    }
    /* An infinity is the only finite-looking value that survives halving;
     * the zero test keeps negative zero out of this branch. */
    if (value != 0.0 && value * 0.5 == value)
    {
        MewCrtEmitSpecialFloat(sink, spec, "inf", 3U, MewCrtIsNegative(value));
        return;
    }

    if (MewCrtIsNegative(value))
    {
        sign = '-';
        value = -value;
    }
    else if (spec->plus)
    {
        sign = '+';
    }
    else if (spec->space)
    {
        sign = ' ';
    }

    length = MewCrtFixedDouble(body, value, precision);
    padding = 0;
    if (spec->width > 0 && (size_t)spec->width > length + (sign != '\0' ? 1U : 0U))
    {
        padding = (size_t)spec->width - length - (sign != '\0' ? 1U : 0U);
    }

    if (spec->left)
    {
        if (sign != '\0') MewCrtPut(sink, sign);
        for (i = 0; i < length; i++) MewCrtPut(sink, body[i]);
        MewCrtRepeat(sink, ' ', padding);
    }
    else if (spec->zero)
    {
        if (sign != '\0') MewCrtPut(sink, sign);
        MewCrtRepeat(sink, '0', padding);
        for (i = 0; i < length; i++) MewCrtPut(sink, body[i]);
    }
    else
    {
        MewCrtRepeat(sink, ' ', padding);
        if (sign != '\0') MewCrtPut(sink, sign);
        for (i = 0; i < length; i++) MewCrtPut(sink, body[i]);
    }
}

static unsigned long long MewCrtReadUnsigned(va_list* args, int length, int signed_value,
                                             int* negative)
{
    unsigned long long value;

    *negative = 0;
    if (signed_value)
    {
        long long signed_result;
        switch (length)
        {
            case 1: signed_result = (signed char)va_arg(*args, int); break;
            case 2: signed_result = (short)va_arg(*args, int); break;
            case 4: signed_result = va_arg(*args, long); break;
            case 8: signed_result = va_arg(*args, long long); break;
            default: signed_result = va_arg(*args, int); break;
        }
        if (signed_result < 0)
        {
            *negative = 1;
            return (unsigned long long)(-(signed_result + 1)) + 1ULL;
        }
        return (unsigned long long)signed_result;
    }

    switch (length)
    {
        case 1: value = (unsigned char)va_arg(*args, unsigned int); break;
        case 2: value = (unsigned short)va_arg(*args, unsigned int); break;
        case 4: value = va_arg(*args, unsigned long); break;
        case 8: value = va_arg(*args, unsigned long long); break;
        default: value = va_arg(*args, unsigned int); break;
    }
    return value;
}

static int MewCrtVFormatNarrow(char* buffer, size_t size, const char* format, va_list args)
{
    MewCrtSink sink;

    sink.buffer = buffer;
    sink.size = size;
    sink.count = 0;

    if (!format)
    {
        if (size != 0) buffer[0] = '\0';
        return -1;
    }

    while (*format != '\0')
    {
        MewCrtSpec spec;
        int length = 0;
        char conversion;

        if (*format != '%')
        {
            MewCrtPut(&sink, *format++);
            continue;
        }
        format++;
        if (*format == '%')
        {
            MewCrtPut(&sink, '%');
            format++;
            continue;
        }

        spec.left = 0;
        spec.zero = 0;
        spec.plus = 0;
        spec.space = 0;
        spec.alt = 0;
        spec.width = 0;
        spec.precision = -1;

        for (;;)
        {
            if (*format == '-') { spec.left = 1; format++; }
            else if (*format == '0') { spec.zero = 1; format++; }
            else if (*format == '+') { spec.plus = 1; format++; }
            else if (*format == ' ') { spec.space = 1; format++; }
            else if (*format == '#') { spec.alt = 1; format++; }
            else break;
        }

        if (*format == '*')
        {
            spec.width = va_arg(args, int);
            if (spec.width < 0) { spec.left = 1; spec.width = -spec.width; }
            format++;
        }
        else
        {
            while (*format >= '0' && *format <= '9')
            {
                spec.width = spec.width * 10 + (*format - '0');
                format++;
            }
        }

        if (*format == '.')
        {
            format++;
            spec.precision = 0;
            if (*format == '*')
            {
                spec.precision = va_arg(args, int);
                if (spec.precision < 0) spec.precision = -1;
                format++;
            }
            else
            {
                while (*format >= '0' && *format <= '9')
                {
                    spec.precision = spec.precision * 10 + (*format - '0');
                    format++;
                }
            }
        }

        if (*format == 'h')
        {
            format++;
            if (*format == 'h') { length = 1; format++; }
            else { length = 2; }
        }
        else if (*format == 'l')
        {
            format++;
            if (*format == 'l') { length = 8; format++; }
            else { length = 4; }
        }
        else if (*format == 'z' || *format == 'j' || *format == 't' || *format == 'L')
        {
            length = 8;
            format++;
        }
        else if (*format == 'I')
        {
            /* MSVC's size_t/pointer length modifier: I64 (8 bytes), I32
             * (4 bytes), or a bare I (size_t, pointer-sized). The bare form
             * must consume exactly one argument like any other length. */
            format++;
            if (*format == '6' && format[1] == '4')
            {
                length = 8;
                format += 2;
            }
            else if (*format == '3' && format[1] == '2')
            {
                length = 4;
                format += 2;
            }
            else
            {
                length = (int)sizeof(size_t);
            }
        }

        conversion = *format;
        if (conversion == '\0')
        {
            MewCrtPut(&sink, '%');
            break;
        }
        format++;

        switch (conversion)
        {
            case 'd':
            case 'i':
            {
                int negative;
                unsigned long long value = MewCrtReadUnsigned(&args, length, 1, &negative);
                MewCrtEmitNumber(&sink, &spec, value, negative, 1, 10U, 0, 0);
                break;
            }
            case 'u':
            {
                int negative;
                unsigned long long value = MewCrtReadUnsigned(&args, length, 0, &negative);
                MewCrtEmitNumber(&sink, &spec, value, 0, 0, 10U, 0, 0);
                break;
            }
            case 'x':
            case 'X':
            {
                int negative;
                unsigned long long value = MewCrtReadUnsigned(&args, length, 0, &negative);
                MewCrtEmitNumber(&sink, &spec, value, 0, 0, 16U, conversion == 'X', 0);
                break;
            }
            case 'o':
            {
                int negative;
                unsigned long long value = MewCrtReadUnsigned(&args, length, 0, &negative);
                MewCrtEmitNumber(&sink, &spec, value, 0, 0, 8U, 0, 0);
                break;
            }
            case 'p':
            {
                void* pointer = va_arg(args, void*);
                MewCrtEmitNumber(&sink, &spec, (unsigned long long)(UINT_PTR)pointer,
                                 0, 0, 16U, 0, 1);
                break;
            }
            case 'c':
            {
                char character = (char)va_arg(args, int);
                MewCrtEmitText(&sink, &spec, &character, 1U);
                break;
            }
            case 's':
            {
                const char* text = va_arg(args, const char*);
                size_t text_length = 0;
                if (!text) text = "(null)";
                while (text[text_length] != '\0') text_length++;
                MewCrtEmitText(&sink, &spec, text, text_length);
                break;
            }
            case 'n':
            {
                int* out = va_arg(args, int*);
                if (out) *out = (int)sink.count;
                break;
            }
            case 'f':
            case 'F':
            case 'e':
            case 'E':
            case 'g':
            case 'G':
            case 'a':
            case 'A':
            {
                double value = va_arg(args, double);
                MewCrtEmitFloat(&sink, &spec, value);
                break;
            }
            default:
                MewCrtPut(&sink, '%');
                MewCrtPut(&sink, conversion);
                break;
        }
    }

    if (sink.size != 0)
    {
        size_t end = sink.count < sink.size ? sink.count : sink.size - 1U;
        sink.buffer[end] = '\0';
    }
    return (int)sink.count;
}

int snprintf(char* buffer, size_t size, const char* format, ...)
{
    int result;
    va_list args;

    va_start(args, format);
    result = MewCrtVFormatNarrow(buffer, size, format, args);
    va_end(args);
    return result;
}

/* MSVC spelling of snprintf, used by the Mewjector loader's crash writer.
 * Returning the would-be length (rather than MSVC's -1) is safe: the caller
 * clamps anything at or above the buffer size. */
int _snprintf(char* buffer, size_t size, const char* format, ...)
{
    int result;
    va_list args;

    va_start(args, format);
    result = MewCrtVFormatNarrow(buffer, size, format, args);
    va_end(args);
    return result;
}

int vsnprintf(char* buffer, size_t size, const char* format, va_list args)
{
    return MewCrtVFormatNarrow(buffer, size, format, args);
}

/* Wide writer used by MewUI's typed text formatting. The format is ASCII in
 * every call site (L"%d", L"%u", L"%%.%uf" and its result), so the format is
 * narrowed first and the formatted digits are widened back. */
int _snwprintf(wchar_t* buffer, size_t count, const wchar_t* format, ...)
{
    char narrow_format[MEW_CRT_FORMAT_SCRATCH];
    char narrow_output[MEW_CRT_FLOAT_SCRATCH];
    size_t i;
    int written;
    va_list args;

    if (!buffer || count == 0 || !format)
    {
        return -1;
    }

    for (i = 0; format[i] != L'\0' && i + 1 < sizeof(narrow_format); i++)
    {
        narrow_format[i] = (format[i] < MEW_CRT_ASCII_MAX) ? (char)format[i] : '?';
    }
    narrow_format[i] = '\0';

    va_start(args, format);
    written = MewCrtVFormatNarrow(narrow_output, sizeof(narrow_output), narrow_format, args);
    va_end(args);

    if (written < 0 || (size_t)written >= sizeof(narrow_output))
    {
        buffer[0] = L'\0';
        return -1;
    }

    for (i = 0; i < count - 1 && narrow_output[i] != '\0'; i++)
    {
        buffer[i] = (wchar_t)(unsigned char)narrow_output[i];
    }
    buffer[i] = L'\0';

    if ((size_t)written >= count)
    {
        return -1;
    }
    return written;
}
