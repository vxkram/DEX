// The engines (image, audio, PDF, downloader) live here as Tauri commands;
// the React side in ../src is UI only, like App/ vs DexCore on the Mac.

/// What the window was handed: enough for the UI to pick image, PDF or audio tools.
#[derive(serde::Serialize)]
struct Inspected {
    path: String,
    name: String,
    bytes: u64,
    kind: &'static str,
}

#[tauri::command]
fn inspect(path: String) -> Result<Inspected, String> {
    let p = std::path::Path::new(&path);
    let bytes = std::fs::metadata(p).map_err(|e| e.to_string())?.len();
    let ext = p
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    let kind = match ext.as_str() {
        "jpg" | "jpeg" | "png" | "heic" | "heif" | "webp" | "avif" | "tif" | "tiff" | "gif" => "image",
        "pdf" => "pdf",
        "wav" | "aif" | "aiff" | "flac" | "m4a" | "aac" | "mp3" => "audio",
        _ => "unknown",
    };
    let name = p.file_name().and_then(|n| n.to_str()).unwrap_or(&path).to_string();
    Ok(Inspected { path, name, bytes, kind })
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![inspect])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
