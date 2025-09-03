import asynchttpserver, asyncdispatch, httpclient, strutils, os, json, sequtils, algorithm, uri, mimetypes, strformat, base64, tables

const
  MUSIC_DIR = "music"
  SERVER_PORT = 8080

type
  MusicSource = enum
    msLocal, msGitHub, msGitLab, msGitRepo
  
  GitConfig = object
    repoUrl: string
    branch: string
    musicPath: string
    token: string  # For private repos
  
  Song = object
    filename: string
    path: string
    title: string
    rawUrl: string  # For git-based sources
    sha: string     # For GitHub blob API

# Forward declarations
proc fetchMusicFromGit(): Future[seq[Song]] {.async, gcsafe.}
proc loadEnvFile()

# Global songs list for URL lookup
var globalSongs: seq[Song]

proc loadEnvFile() =
  # Simple .env file loader
  let envFile = ".env"
  if fileExists(envFile):
    echo "Loading .env file..."
    for line in lines(envFile):
      let trimmedLine = line.strip()
      if trimmedLine.len > 0 and not trimmedLine.startsWith("#"):
        let parts = trimmedLine.split("=", 1)
        if parts.len == 2:
          let key = parts[0].strip()
          let value = parts[1].strip()
          putEnv(key, value)
          echo "  Set ", key, "=", value

proc getMusicSource(): MusicSource =
  let sourceEnv = getEnv("MUSIC_SOURCE").toLowerAscii()
  case sourceEnv
  of "github": msGitHub
  of "gitlab": msGitLab  
  of "git": msGitRepo
  else: msLocal

proc getGitConfig(): GitConfig =
  result.repoUrl = getEnv("GIT_REPO_URL")
  result.branch = getEnv("GIT_BRANCH")
  result.musicPath = getEnv("GIT_MUSIC_PATH")
  result.token = getEnv("GIT_TOKEN")
  
  # Set defaults
  if result.branch == "": result.branch = "main"
  if result.musicPath == "": result.musicPath = "music"
  
  # Remove leading slash from music path if present
  if result.musicPath.startsWith("/"):
    result.musicPath = result.musicPath[1..^1]

proc getMimeType(filename: string): string =
  let ext = splitFile(filename).ext.toLowerAscii()
  case ext
  of ".flac": "audio/flac"
  of ".mp3": "audio/mpeg"
  of ".wav": "audio/wav"
  of ".ogg": "audio/ogg"
  of ".m4a": "audio/mp4"
  else: "application/octet-stream"

proc parseGitHubUrl(repoUrl: string): (string, string) =
  # Parse "https://github.com/owner/repo" or "owner/repo"
  let cleanUrl = repoUrl.replace("https://github.com/", "").replace("http://github.com/", "")
  let parts = cleanUrl.split("/")
  if parts.len >= 2:
    return (parts[0], parts[1])
  else:
    raise newException(ValueError, "Invalid GitHub repository URL format")

proc parseGitLabUrl(repoUrl: string): (string, string) =
  # Parse "https://gitlab.com/owner/repo" or "owner/repo" 
  let cleanUrl = repoUrl.replace("https://gitlab.com/", "").replace("http://gitlab.com/", "")
  let parts = cleanUrl.split("/")
  if parts.len >= 2:
    return (parts[0], parts[1])
  else:
    raise newException(ValueError, "Invalid GitLab repository URL format")

proc getGitHubApiUrl(owner, repo, path, branch: string): string =
  return fmt"https://api.github.com/repos/{owner}/{repo}/contents/{path}?ref={branch}"

proc getGitLabApiUrl(owner, repo, path, branch: string): string =
  let encodedPath = encodeUrl(path)
  return fmt"https://gitlab.com/api/v4/projects/{owner}%2F{repo}/repository/tree?path={encodedPath}&ref={branch}"

proc getGitHubRawUrl(owner, repo, path, filename, branch: string): string =
  return fmt"https://raw.githubusercontent.com/{owner}/{repo}/{branch}/{path}/{filename}"

proc getGitLabRawUrl(owner, repo, path, filename, branch: string): string =
  return fmt"https://gitlab.com/{owner}/{repo}/-/raw/{branch}/{path}/{filename}"

proc scanMusicDirectory(dir: string): seq[Song] =
  {.cast(gcsafe).}:
    var songs: seq[Song] = @[]
  let source = getMusicSource()
  
  case source
  of msLocal:
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
            title: name,
            rawUrl: "",
            sha: ""
          ))
  
  of msGitHub, msGitLab, msGitRepo:
    # Fetch music list from Git repository
    songs = waitFor fetchMusicFromGit()
  
  songs.sort(proc(a, b: Song): int = cmp(a.title, b.title))
  globalSongs = songs  # Store globally for URL lookup
  return songs

proc fetchMusicFromGit(): Future[seq[Song]] {.async, gcsafe.} =
  var songs: seq[Song] = @[]
  let config = getGitConfig()
  let source = getMusicSource()
  
  echo "🔍 Debug - Git config:"
  echo "  Source: ", source
  echo "  Repo URL: ", config.repoUrl
  echo "  Branch: ", config.branch
  echo "  Music Path: ", config.musicPath
  echo "  Token present: ", config.token != ""
  
  if config.repoUrl == "":
    echo "Warning: GIT_REPO_URL not set"
    return songs
  
  try:
    let client = newAsyncHttpClient()
    defer: client.close()
    
    # Add authorization header if token is provided
    if config.token != "":
      case source
      of msGitHub:
        client.headers = newHttpHeaders({"Authorization": "token " & config.token})
      of msGitLab:
        client.headers = newHttpHeaders({"PRIVATE-TOKEN": config.token})
      else:
        client.headers = newHttpHeaders({"Authorization": "Bearer " & config.token})
    
    var apiUrl: string
    case source
    of msGitHub:
      let (owner, repo) = parseGitHubUrl(config.repoUrl)
      echo "🔍 Debug - Parsed GitHub URL: owner=", owner, " repo=", repo
      apiUrl = getGitHubApiUrl(owner, repo, config.musicPath, config.branch)
    of msGitLab:
      let (owner, repo) = parseGitLabUrl(config.repoUrl)
      apiUrl = getGitLabApiUrl(owner, repo, config.musicPath, config.branch)
    else:
      echo "Generic git repositories not yet supported"
      return songs
    
    echo "Fetching music list from: ", apiUrl
    let response = await client.get(apiUrl)
    
    echo "🔍 Debug - GitHub API response status: ", response.status
    
    if not response.status.startsWith("200"):
      echo "Failed to fetch music list: ", response.status
      let responseBody = await response.body
      echo "Response: ", responseBody
      return songs
    
    let jsonBody = await response.body
    echo "🔍 Debug - Response body length: ", jsonBody.len
    echo "🔍 Debug - First 200 chars: ", jsonBody[0..<min(200, jsonBody.len)]
    let jsonData = parseJson(jsonBody)
    echo "🔍 Debug - JSON array length: ", jsonData.len
    
    case source
    of msGitHub:
      # GitHub API returns array of file objects
      for item in jsonData:
        echo "🔍 Debug - Item: ", item.hasKey("name"), " name=", 
             (if item.hasKey("name"): item["name"].getStr() else: "N/A"),
             " type=", (if item.hasKey("type"): item["type"].getStr() else: "N/A")
        
        if item.hasKey("name") and item.hasKey("type") and item["type"].getStr() == "file":
          let filename = item["name"].getStr()
          let ext = splitFile(filename).ext.toLowerAscii()
          echo "🔍 Debug - Found file: ", filename, " ext: ", ext
          if ext in [".flac", ".mp3", ".wav", ".ogg", ".m4a"]:
            # Use GitHub's provided download_url which includes proper authentication
            let rawUrl = if item.hasKey("download_url") and item["download_url"].kind != JNull: 
                          item["download_url"].getStr()
                         else:
                          # Fallback to constructed URL
                          let (owner, repo) = parseGitHubUrl(config.repoUrl)
                          getGitHubRawUrl(owner, repo, config.musicPath, filename, config.branch)
            
            let title = splitFile(filename).name
            echo "🔍 Debug - Adding song: ", title, " URL: ", rawUrl
            
            # Get SHA for blob API access
            let sha = if item.hasKey("sha"): item["sha"].getStr() else: ""
            
            songs.add(Song(
              filename: filename,
              path: filename,
              title: title,
              rawUrl: rawUrl,
              sha: sha
            ))
    
    of msGitLab:
      # GitLab API returns array of file objects
      for item in jsonData:
        if item.hasKey("name") and item.hasKey("type") and item["type"].getStr() == "blob":
          let filename = item["name"].getStr()
          let ext = splitFile(filename).ext.toLowerAscii()
          if ext in [".flac", ".mp3", ".wav", ".ogg", ".m4a"]:
            let (owner, repo) = parseGitLabUrl(config.repoUrl)
            let rawUrl = getGitLabRawUrl(owner, repo, config.musicPath, filename, config.branch)
            let title = splitFile(filename).name
            songs.add(Song(
              filename: filename,
              path: filename,
              title: title,
              rawUrl: rawUrl,
              sha: ""  # GitLab doesn't use SHA the same way
            ))
    
    else:
      discard
    
    echo "Found ", songs.len, " music files in repository"
    
  except Exception as e:
    echo "Error fetching music from git: ", e.msg
  
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

proc serveFile(filename: string): Future[string] {.async, gcsafe.} =
  {.cast(gcsafe).}:
    let source = getMusicSource()
  
  case source
  of msLocal:
    let filePath = MUSIC_DIR / filename
    if not fileExists(filePath):
      return ""
    try:
      return readFile(filePath)
    except:
      return ""
  
  of msGitHub, msGitLab, msGitRepo:
    # Stream file directly from GitHub API using blob endpoint
    let config = getGitConfig()
    let client = newAsyncHttpClient()
    defer: client.close()
    
    try:
      # Add authorization header
      if config.token != "":
        client.headers = newHttpHeaders({"Authorization": "token " & config.token})
      
      # Find the song to get its SHA
      for song in globalSongs:
        if song.filename == filename:
          if song.sha != "":
            # Use the stored SHA to get file content via blobs API
            let (owner, repo) = parseGitHubUrl(config.repoUrl)
            let blobUrl = fmt"https://api.github.com/repos/{owner}/{repo}/git/blobs/{song.sha}"
            echo "Getting blob from: ", blobUrl
            
            # Set accept header for raw content
            client.headers["Accept"] = "application/vnd.github.raw"
            
            let blobResponse = await client.get(blobUrl)
            
            if blobResponse.status.startsWith("200"):
              echo "Successfully fetched file via GitHub blobs API"
              return await blobResponse.body
            else:
              echo "Failed to fetch blob: ", blobResponse.status
              return ""
          else:
            echo "No SHA available for file: ", filename
            return ""
          
    except Exception as e:
      echo "Error streaming file via GitHub API: ", e.msg
      return ""
    
    echo "Song not found: ", filename
    return ""

proc handleRequest(req: Request) {.async, gcsafe.} =
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

proc main() {.async, gcsafe.} =
  # Load environment variables from .env file (only for local development)
  if fileExists(".env"):
    loadEnvFile()
  
  let server = newAsyncHttpServer()
  let source = getMusicSource()
  
  echo "🎵 Nim Music Player Server"
  echo "Music source: ", source
  
  case source
  of msLocal:
    echo "Music directory: ", MUSIC_DIR
    if not dirExists(MUSIC_DIR):
      echo "⚠️  Warning: Music directory ", MUSIC_DIR, " does not exist!"
      echo "   Please create the directory and add your music files."
  
  of msGitHub, msGitLab, msGitRepo:
    let config = getGitConfig()
    echo "Git repository: ", config.repoUrl
    echo "Branch: ", config.branch
    echo "Music path: ", config.musicPath
    echo "Token configured: ", (if config.token != "": "Yes" else: "No")
  
  echo "Server starting on http://localhost:", SERVER_PORT
  
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