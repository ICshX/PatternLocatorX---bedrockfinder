PatternLocatorX is a utility for Minecraft that allows you to find exact coordinates based on a specific bedrock pattern in your world. By analyzing bedrock layers, it helps locate precise spots using seed-based searches.

## Features
- Supports **Overworld** and **Nether** (floor and ceiling) searches.
- Flexible bedrock pattern input.
- Automatic search height based on dimension.
- Multi-directional pattern scanning.
- Outputs exact coordinates for matches.
- Search starting point

## Requirements
- **Zig 0.10.1**: Download from [ziglang.org](https://ziglang.org/download/).
- Windows or compatible OS for running the `.bat` scripts.

## Usage
  ##### First time use : Add Zig-Path (exmpl: C:\Users\USER\Desktop\zig-windows-x86_64-0.10.1\zig-windows-x86_64-0.10.1\zig.exe) {can be "/"}
  
1. Run the provided `.bat` file.
2. Enter the Minecraft seed.
3. Specify the search range (default: 10000).
4. Input your bedrock pattern row by row or load a previous pattern file.
5. Choose directions to check (`N`, `E`, `S`, `W`) or leave blank for all.
6. Select the dimension: `overworld`, `netherfloor`, or `netherceiling`.
7. The program outputs matching coordinates in the console.

## Notes
- Ensure your seed is correct; SeedcrackerX can help find it on servers.
- The search height is automatically set based on dimension.
- Patterns are saved in the `Pattern-log` directory for reuse.
- 1.18+ only
- DO NOT USE THE TERMINAL IN FULLSCREEN (there will be visual bugs)

## License
This project is released under the MIT License. See `LICENSE` for details.

## Keywords
Minecraft bedrock pattern finder
Bedrock-Pattern Locator
Minecraft world coordinates
seed based bedrock pattern search
Overworld bedrock scanner
Nether bedrock ceiling/floor locator
Zig programming Minecraft tool
Bedrock Finder 1.18+
Custom bedrock pattern input
multi-directional pattern scanning Minecraft
PatternLocatorX
