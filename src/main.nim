import asynchttpserver, asyncdispatch, httpclient, strutils, os, json, sequtils, algorithm, uri, mimetypes, strformat

const
  MUSIC_DIR = "music"
  SERVER_PORT = 8080

type
  Song = object
    filename: string
    path: string
    title: string

proc getMimeType(filename: string): string =
  let ext = splitFile(filename).ext.toLowerAscii()
  case ext
  of ".flac": "audio/flac"
  of ".mp3": "audio/mpeg"
  of ".wav": "audio/wav"
  of ".ogg": "audio/ogg"
  of ".m4a": "audio/mp4"
  else: "application/octet-stream"

proc scanMusicDirectory(dir: string): seq[Song] =
  var songs: seq[Song] = @[]
  
  if not dirExists(dir):
    echo "Warning: Music directory ", dir, " does not exist"
    return songs
  
  for kind, path in walkDir(dir):
    if kind == pcFile:
      let (_, name, ext) = splitFile(path)
      if ext.toLowerAscii() in [".flac", ".mp3", ".wav", ".ogg", ".m4a"]:
        songs.add(Song(
          filename: extractFilename(path),
          path: path,
          title: name
        ))
  
  songs.sort(proc(a, b: Song): int = cmp(a.title, b.title))
  return songs

proc generateHTML(songs: seq[Song]): string =
  result = """
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Nim Music Player</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            color: #333;
        }
        
        .container {
            max-width: 1200px;
            margin: 0 auto;
            padding: 20px;
        }
        
        .header {
            text-align: center;
            margin-bottom: 30px;
            color: white;
        }
        
        .header h1 {
            font-size: 2.5em;
            margin-bottom: 10px;
            text-shadow: 2px 2px 4px rgba(0,0,0,0.3);
        }
        
        .player-section {
            background: rgba(255, 255, 255, 0.95);
            border-radius: 15px;
            padding: 25px;
            margin-bottom: 30px;
            box-shadow: 0 10px 30px rgba(0,0,0,0.2);
            backdrop-filter: blur(10px);
        }
        
        .current-song {
            text-align: center;
            margin-bottom: 20px;
        }
        
        .current-song h3 {
            font-size: 1.3em;
            margin-bottom: 10px;
            color: #444;
        }
        
        .audio-player {
            width: 100%;
            height: 60px;
            background: #f8f9fa;
            border-radius: 10px;
            outline: none;
        }
        
        .playlist {
            background: rgba(255, 255, 255, 0.95);
            border-radius: 15px;
            padding: 25px;
            box-shadow: 0 10px 30px rgba(0,0,0,0.2);
            backdrop-filter: blur(10px);
        }
        
        .playlist h2 {
            margin-bottom: 20px;
            color: #444;
            font-size: 1.5em;
        }
        
        .song-list {
            list-style: none;
        }
        
        .song-item {
            display: flex;
            align-items: center;
            padding: 15px;
            margin-bottom: 10px;
            background: #f8f9fa;
            border-radius: 10px;
            cursor: pointer;
            transition: all 0.3s ease;
            border-left: 4px solid transparent;
        }
        
        .song-item:hover {
            background: #e9ecef;
            transform: translateX(5px);
            border-left-color: #667eea;
        }
        
        .song-item.active {
            background: linear-gradient(135deg, #667eea, #764ba2);
            color: white;
            border-left-color: #fff;
        }
        
        .song-number {
            min-width: 40px;
            font-weight: bold;
            opacity: 0.7;
        }
        
        .song-title {
            flex: 1;
            font-size: 1.1em;
        }
        
        .song-format {
            font-size: 0.9em;
            opacity: 0.7;
            background: rgba(0,0,0,0.1);
            padding: 4px 8px;
            border-radius: 4px;
        }
        
        .controls {
            display: flex;
            justify-content: center;
            gap: 15px;
            margin-top: 20px;
        }
        
        .control-btn {
            background: linear-gradient(135deg, #667eea, #764ba2);
            color: white;
            border: none;
            padding: 12px 20px;
            border-radius: 25px;
            cursor: pointer;
            font-size: 1em;
            transition: all 0.3s ease;
            box-shadow: 0 4px 15px rgba(0,0,0,0.2);
        }
        
        .control-btn:hover {
            transform: translateY(-2px);
            box-shadow: 0 6px 20px rgba(0,0,0,0.3);
        }
        
        .control-btn:active {
            transform: translateY(0);
        }
        
        .empty-state {
            text-align: center;
            color: #666;
            font-size: 1.2em;
            margin: 40px 0;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🎵 Nim Music Player</h1>
            <p>Personal Music Player for everywhere</p>
        </div>
        
        <div class="player-section">
            <div class="current-song">
                <h3 id="currentSong">Select a song to play</h3>
            </div>
            <audio id="audioPlayer" class="audio-player" controls>
                Your browser does not support the audio element.
            </audio>
            <div class="controls">
                <button class="control-btn" onclick="previousSong()">⏮️ Previous</button>
                <button class="control-btn" onclick="togglePlayPause()">⏯️ Play/Pause</button>
                <button class="control-btn" onclick="nextSong()">⏭️ Next</button>
            </div>
        </div>
        
        <div class="playlist">"""
  
  result.add(fmt"            <h2>📁 Music Library ({songs.len} songs)</h2>")
  result.add("""
            <ul class="song-list" id="songList">
""")
  
  if songs.len == 0:
    result.add("""
                <div class="empty-state">
                    <p>No music files found in music directory</p>
                    <p>Supported formats: FLAC, MP3, WAV, OGG, M4A</p>
                </div>
""")
  else:
    for i, song in songs:
      let ext = splitFile(song.filename).ext.toUpperAscii().replace(".", "")
      result.add(fmt"""
                <li class="song-item" onclick="playSong('{song.filename}', '{song.title}', {i})">
                    <span class="song-number">{i + 1}.</span>
                    <span class="song-title">{song.title}</span>
                    <span class="song-format">{ext}</span>
                </li>
""")
  
  result.add("""
            </ul>
        </div>
    </div>
    
    <script>
        let currentSongIndex = -1;
        let songs = """ & $(%songs.mapIt(%{"filename": %it.filename, "title": %it.title})) & """;
        const audioPlayer = document.getElementById('audioPlayer');
        const currentSongElement = document.getElementById('currentSong');
        const songList = document.getElementById('songList');
        
        function playSong(filename, title, index) {
            audioPlayer.src = '/stream/' + encodeURIComponent(filename);
            audioPlayer.load();
            audioPlayer.play();
            currentSongElement.textContent = title;
            currentSongIndex = index;
            
            // Update active song styling
            const songItems = songList.querySelectorAll('.song-item');
            songItems.forEach(item => item.classList.remove('active'));
            songItems[index].classList.add('active');
        }
        
        function togglePlayPause() {
            if (audioPlayer.paused) {
                audioPlayer.play();
            } else {
                audioPlayer.pause();
            }
        }
        
        function nextSong() {
            if (songs.length === 0) return;
            currentSongIndex = (currentSongIndex + 1) % songs.length;
            const song = songs[currentSongIndex];
            playSong(song.filename, song.title, currentSongIndex);
        }
        
        function previousSong() {
            if (songs.length === 0) return;
            currentSongIndex = currentSongIndex <= 0 ? songs.length - 1 : currentSongIndex - 1;
            const song = songs[currentSongIndex];
            playSong(song.filename, song.title, currentSongIndex);
        }
        
        // Auto-play next song when current song ends
        audioPlayer.addEventListener('ended', nextSong);
        
        // Keyboard shortcuts
        document.addEventListener('keydown', function(e) {
            if (e.code === 'Space') {
                e.preventDefault();
                togglePlayPause();
            } else if (e.code === 'ArrowRight') {
                nextSong();
            } else if (e.code === 'ArrowLeft') {
                previousSong();
            }
        });
    </script>
</body>
</html>
""")

proc serveFile(filename: string): Future[string] {.async.} =
  let filePath = MUSIC_DIR / filename
  
  if not fileExists(filePath):
    return ""
  
  try:
    return readFile(filePath)
  except:
    return ""

proc handleRequest(req: Request) {.async.} =
  let path = req.url.path
  
  try:
    if path == "/" or path == "":
      # Serve main page
      let songs = scanMusicDirectory(MUSIC_DIR)
      let html = generateHTML(songs)
      await req.respond(Http200, html, newHttpHeaders([("Content-Type", "text/html")]))
    
    elif path.startsWith("/stream/"):
      # Stream audio file
      let filename = decodeUrl(path.replace("/stream/", ""))
      let content = await serveFile(filename)
      
      if content == "":
        await req.respond(Http404, "File not found")
      else:
        let mimeType = getMimeType(filename)
        let headers = newHttpHeaders([
          ("Content-Type", mimeType),
          ("Accept-Ranges", "bytes"),
          ("Content-Length", $content.len)
        ])
        await req.respond(Http200, content, headers)
    
    else:
      await req.respond(Http404, "Not found")
      
  except Exception as e:
    echo "Error handling request: ", e.msg
    await req.respond(Http500, "Internal server error")

proc main() {.async.} =
  let server = newAsyncHttpServer()
  
  echo "🎵 FLAC Music Player Server"
  echo "Music directory: ", MUSIC_DIR
  echo "Server starting on http://localhost:", SERVER_PORT
  
  if not dirExists(MUSIC_DIR):
    echo "⚠️  Warning: Music directory ", MUSIC_DIR, " does not exist!"
    echo "   Please create the directory and add your FLAC files."
  else:
    let songs = scanMusicDirectory(MUSIC_DIR)
    echo "🎶 Found ", songs.len, " music files"
  
  echo "🌐 Open http://localhost:", SERVER_PORT, " in your browser"
  echo "⌨️  Keyboard shortcuts: Space (play/pause), ← → (prev/next)"
  echo "🛑 Press Ctrl+C to stop the server"
  
  server.listen(Port(SERVER_PORT))
  
  while true:
    if server.shouldAcceptRequest():
      await server.acceptRequest(handleRequest)
    else:
      await sleepAsync(1)

when isMainModule:
  waitFor main()