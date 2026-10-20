# DEX for Windows

A rebuild of DEX for Windows 10/11 with Tauri 2 (Rust) and React. The Mac app lives in [`../mac`](../mac). For why it's built this way, and what replaces each Apple framework, see [ADR 0007](../docs/adr/0007-windows.md).

Status: early. So far it's only the window and the drop zone.

## Set up the PC (once)
1. **Microsoft C++ Build Tools**: install [Visual Studio Build Tools](https://visualstudio.microsoft.com/visual-cpp-build-tools/) and tick **Desktop development with C++**.
2. **Rust**: install from [rustup.rs](https://rustup.rs) (choose the default, `x86_64-pc-windows-msvc`).
3. **Node.js 22 LTS** from [nodejs.org](https://nodejs.org).
4. **Git** from [git-scm.com](https://git-scm.com).

WebView2 is already part of Windows 10 and 11.

## Build
```powershell
git clone https://github.com/vxkram/DEX.git
cd DEX\windows
npm install
npm run tauri dev      # run with live reload
npm run tauri build    # installer in src-tauri\target\release\bundle\nsis\
```
The first `tauri dev` compiles every Rust dependency, which takes a few minutes. Later runs are quick.

## Layout
```
src/            React UI only (like mac/App)
src-tauri/      Rust: engines as Tauri commands (like mac/Packages/DexCore)
  src/lib.rs    commands registered with the app
  icons/        made from ../design/AppIcon-1024.png: npx tauri icon ../design/AppIcon-1024.png
```
