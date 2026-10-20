import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { getCurrentWebview } from "@tauri-apps/api/webview";

type Inspected = {
  path: string;
  name: string;
  bytes: number;
  kind: "image" | "pdf" | "audio" | "unknown";
};

export default function App() {
  const [over, setOver] = useState(false);
  const [file, setFile] = useState<Inspected | null>(null);
  const [error, setError] = useState<string | null>(null);

  // Tauri delivers dropped files as real paths, so the Rust side can read them.
  useEffect(() => {
    const unlisten = getCurrentWebview().onDragDropEvent(async (event) => {
      const { type } = event.payload;
      if (type === "enter" || type === "over") setOver(true);
      else if (type === "leave") setOver(false);
      else if (type === "drop") {
        setOver(false);
        const [path] = event.payload.paths;
        if (!path) return;
        try {
          setFile(await invoke<Inspected>("inspect", { path }));
          setError(null);
        } catch (e) {
          setError(String(e));
        }
      }
    });
    return () => {
      unlisten.then((f) => f());
    };
  }, []);

  return (
    <main className={`drop${over ? " over" : ""}`}>
      <h1>DEX</h1>
      {file ? (
        <p>
          <span className="file">{file.name}</span> · {file.kind} · {file.bytes.toLocaleString()} bytes
        </p>
      ) : (
        <p>Drop an image, a PDF or an audio file</p>
      )}
      {error && <p>{error}</p>}
    </main>
  );
}
