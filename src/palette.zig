// PICO-8 palette: 16 standard + 16 extended colors as ARGB8888
pub const colors: [32]u32 = .{
    // Standard 16 colors (0-15)
    0xFF000000, // 0  black
    0xFF1D2B53, // 1  dark blue
    0xFF7E2553, // 2  dark purple
    0xFF008751, // 3  dark green
    0xFFAB5236, // 4  brown
    0xFF5F574F, // 5  dark grey
    0xFFC2C3C7, // 6  light grey
    0xFFFFF1E8, // 7  white
    0xFFFF004D, // 8  red
    0xFFFFA300, // 9  orange
    0xFFFFEC27, // 10 yellow
    0xFF00E436, // 11 green
    0xFF29ADFF, // 12 blue
    0xFF83769C, // 13 indigo
    0xFFFF77A8, // 14 pink
    0xFFFFCCAA, // 15 peach

    // Extended 16 colors (128-143, stored at indices 16-31)
    0xFF291814, // 128
    0xFF111D35, // 129
    0xFF422136, // 130
    0xFF125359, // 131
    0xFF742F29, // 132
    0xFF49333B, // 133
    0xFFA28879, // 134
    0xFFF3EF7D, // 135
    0xFFBE1250, // 136
    0xFFFF6C24, // 137
    0xFFA8E72E, // 138
    0xFF00B543, // 139
    0xFF065AB5, // 140
    0xFF754665, // 141
    0xFFFF6E59, // 142
    0xFFFF9D81, // 143
};
