import asynchttpserver, asyncdispatch, httpclient, strutils, os, json, sequtils, algorithm, uri, mimetypes, strformat, base64, tables, times

const
  MUSIC_DIR = "music"
  DEFAULT_PORT = 3478

proc getServerPort(): int =
  ## Get server port from environment variable or use default
  let portEnv = getEnv("PORT")
  if portEnv != "":
    try:
      return parseInt(portEnv)
    except:
      echo "⚠️  Invalid PORT environment variable, using default"
  return DEFAULT_PORT

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
    format: string   # File format (MP3, FLAC, etc.)
    rawUrl: string   # For git-based sources
    sha: string      # For GitHub blob API

# Forward declarations
proc fetchMusicFromGit(): Future[seq[Song]] {.async, gcsafe.}
proc loadEnvFile()

# Global songs list for URL lookup and favorites
var globalSongs: seq[Song]
var userFavorites: seq[string] = @[]  # Simple favorites list
var localFiles: Table[string, string] = initTable[string, string]()
var userPlaylists {.global.}: Table[string, seq[string]] = initTable[string, seq[string]]()

# GitHub repository configuration
const REPO_OWNER = "arm"
const REPO_NAME = "tim_music"  
const GITHUB_TOKEN = ""  # Add your GitHub token here if repo is private

# Cache for music files to avoid repeated GitHub API calls
var musicCache = initTable[string, string]()  # filename -> file content
var cacheHits = 0
var cacheMisses = 0

proc getCacheStats(): string {.gcsafe.} =
  {.cast(gcsafe).}:
    let totalRequests = cacheHits + cacheMisses
    if totalRequests == 0:
      return "Cache: No requests yet"
    let hitRate = (cacheHits.float / totalRequests.float) * 100.0
    return fmt"Cache: {musicCache.len} files, {cacheHits} hits, {cacheMisses} misses ({hitRate:.1f}% hit rate)"

proc loadLocalPlaylists() {.gcsafe.} =
  ## Load playlists from local playlists directory
  {.cast(gcsafe).}:
    let playlistsDir = "playlists"
    if not dirExists(playlistsDir):
      return
    
    echo "🔍 Debug - Loading local playlists..."
    
    for kind, path in walkDir(playlistsDir):
      if kind == pcFile and path.endsWith(".json"):
        try:
          let content = readFile(path)
          let data = parseJson(content)
          let playlistName = data["name"].getStr()
          let songs = data["songs"].getElems().mapIt(it.getStr())
          userPlaylists[playlistName] = songs
          echo "📋 Loaded local playlist: ", playlistName
        except Exception as e:
          echo "📋 Failed to load playlist ", path, ": ", e.msg
    
    echo "📋 Loaded ", userPlaylists.len, " local playlists"

proc clearCache() {.gcsafe.} =
  {.cast(gcsafe).}:
    musicCache.clear()
    echo "🗑️  Music cache cleared"

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

proc uploadToGitHub(owner, repo, path, filename, content, commitMessage, token, branch: string): Future[bool] {.async.} =
  ## Upload content to GitHub repository
  try:
    let uploadUrl = fmt"https://api.github.com/repos/{owner}/{repo}/contents/{path}/{filename}"
    echo "🔍 Debug - Upload URL: ", uploadUrl
    flushFile(stdout)
    
    let uploadData = %*{
      "message": commitMessage,
      "content": content,
      "branch": branch
    }
    
    var headers = newHttpHeaders([
      ("Content-Type", "application/json"),
      ("Accept", "application/vnd.github.v3+json"),
      ("User-Agent", "Nim-Music-Player")
    ])
    
    if token.len > 0:
      headers["Authorization"] = "token " & token
      echo "🔍 Debug - Using GitHub token for authentication"
      flushFile(stdout)
    
    echo "🔍 Debug - Sending upload request..."
    flushFile(stdout)
    let client = newAsyncHttpClient()
    defer: client.close()
    
    let uploadResponse = await client.request(uploadUrl, httpMethod = HttpPut, body = $uploadData, headers = headers)
    
    if uploadResponse.code == Http201:
      echo "🔍 Debug - File uploaded successfully to GitHub"
      flushFile(stdout)
      return true
    else:
      let uploadBody = await uploadResponse.body
      echo "🔍 Debug - GitHub upload failed: ", uploadResponse.code, " - ", uploadBody
      flushFile(stdout)
      return false
      
  except Exception as e:
    echo "🔍 Debug - GitHub upload error: ", e.msg
    flushFile(stdout)
    return false

proc deleteFromGitHub(owner, repo, path, filename, commitMessage, token, branch: string): Future[bool] {.async.} =
  ## Delete file from GitHub repository
  try:
    # First get the file's SHA (required for deletion)
    let getUrl = fmt"https://api.github.com/repos/{owner}/{repo}/contents/{path}/{filename}?ref={branch}"
    echo "🔍 Debug - Getting file SHA from: ", getUrl
    
    var headers = newHttpHeaders([
      ("Accept", "application/vnd.github.v3+json"),
      ("User-Agent", "Nim-Music-Player")
    ])
    
    if token.len > 0:
      headers["Authorization"] = "token " & token
    
    let client = newAsyncHttpClient()
    defer: client.close()
    
    let getResponse = await client.request(getUrl, httpMethod = HttpGet, headers = headers)
    
    if getResponse.code == Http200:
      let getBody = await getResponse.body
      let jsonData = parseJson(getBody)
      let sha = jsonData["sha"].getStr()
      echo "🔍 Debug - File SHA: ", sha
      
      # Now delete the file
      let deleteUrl = fmt"https://api.github.com/repos/{owner}/{repo}/contents/{path}/{filename}"
      let deleteData = %*{
        "message": commitMessage,
        "sha": sha,
        "branch": branch
      }
      
      headers["Content-Type"] = "application/json"
      let deleteResponse = await client.request(deleteUrl, httpMethod = HttpDelete, body = $deleteData, headers = headers)
      
      if deleteResponse.code == Http200:
        echo "🔍 Debug - File deleted successfully from GitHub"
        return true
      else:
        let deleteBody = await deleteResponse.body
        echo "🔍 Debug - GitHub delete failed: ", deleteResponse.code, " - ", deleteBody
        return false
    else:
      let getBodyError = await getResponse.body
      echo "🔍 Debug - Failed to get file SHA: ", getResponse.code, " - ", getBodyError
      return false
      
  except Exception as e:
    echo "🔍 Debug - GitHub delete error: ", e.msg
    return false

proc fetchSongsFromGitHub(): Future[seq[Song]] {.async, gcsafe.} =
  ## Fetch songs from GitHub repository with format detection
  var songs: seq[Song] = @[]
  let config = getGitConfig()
  let source = getMusicSource()
  
  if source != msGitHub or config.repoUrl == "":
    return songs
  
  try:
    let client = newAsyncHttpClient()
    defer: client.close()
    
    if config.token != "":
      client.headers = newHttpHeaders({"Authorization": "token " & config.token})
    
    let (owner, repo) = parseGitHubUrl(config.repoUrl)
    let apiUrl = fmt"https://api.github.com/repos/{owner}/{repo}/contents/{config.musicPath}?ref={config.branch}"
    
    let response = await client.get(apiUrl)
    
    if response.code == Http200:
      let responseBody = await response.body
      let jsonData = parseJson(responseBody)
      
      for item in jsonData:
        if item["type"].getStr() == "file":
          let filename = item["name"].getStr()
          let ext = filename.split('.')[^1].toLower()
          
          # Only include music files
          if ext in ["mp3", "flac", "wav", "ogg", "m4a"]:
            let format = case ext:
              of "mp3": "MP3"
              of "flac": "FLAC"
              of "wav": "WAV"
              of "ogg": "OGG"
              of "m4a": "M4A"
              else: "Unknown"
            
            let rawUrl = getGitHubRawUrl(owner, repo, config.musicPath, filename, config.branch)
            let sha = item["sha"].getStr()
            
            songs.add(Song(
              filename: filename,
              path: "", # Not used for GitHub
              title: filename,
              format: format,
              rawUrl: rawUrl,
              sha: sha
            ))
      
  except Exception as e:
    echo "🔍 Debug - Error fetching songs from GitHub: ", e.msg
  
  return songs

proc fetchPlaylistsFromGitHub(): Future[Table[string, seq[string]]] {.async, gcsafe.} =
  ## Fetch playlists from GitHub repository
  var playlists = initTable[string, seq[string]]()
  let config = getGitConfig()
  let source = getMusicSource()
  
  if source != msGitHub or config.repoUrl == "":
    echo "🔍 Debug - Not configured for GitHub playlists"
    return playlists
  
  try:
    let client = newAsyncHttpClient()
    defer: client.close()
    
    if config.token != "":
      client.headers = newHttpHeaders({"Authorization": "token " & config.token})
    
    let (owner, repo) = parseGitHubUrl(config.repoUrl)
    let apiUrl = fmt"https://api.github.com/repos/{owner}/{repo}/contents/playlists?ref={config.branch}"
    echo "🔍 Debug - Fetching playlists from: ", apiUrl
    
    let response = await client.get(apiUrl)
    
    if response.code == Http200:
      let responseBody = await response.body
      let jsonData = parseJson(responseBody)
      
      for item in jsonData:
        if item["type"].getStr() == "file" and item["name"].getStr().endsWith(".json"):
          let filename = item["name"].getStr()
          let playlistName = filename[0..^6]  # Remove .json extension
          let downloadUrl = item["download_url"].getStr()
          
          echo "🔍 Debug - Downloading playlist: ", playlistName
          let playlistResponse = await client.get(downloadUrl)
          
          if playlistResponse.code == Http200:
            try:
              let playlistBody = await playlistResponse.body
              let playlistData = parseJson(playlistBody)
              if playlistData.hasKey("songs"):
                let songs = playlistData["songs"].getElems().mapIt(it.getStr())
                playlists[playlistName] = songs
                echo "🔍 Debug - Loaded playlist '", playlistName, "' with ", songs.len, " songs"
            except:
              echo "🔍 Debug - Failed to parse playlist: ", playlistName
    else:
      echo "🔍 Debug - Failed to fetch playlists: ", response.code
      
  except Exception as e:
    echo "🔍 Debug - Error fetching playlists: ", e.msg
  
  return playlists

proc scanMusicDirectory(dir: string): seq[Song] {.gcsafe.} =
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
            let format = case ext.toLowerAscii()
              of ".mp3": "MP3"
              of ".flac": "FLAC"
              of ".wav": "WAV"
              of ".ogg": "OGG"
              of ".m4a": "M4A"
              else: "Unknown"
            
            songs.add(Song(
              filename: extractFilename(path),
              path: path,
              title: name,
              format: format,
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
        
        .toggle-btn {
            background: #6c757d;
            color: white;
            border: none;
            padding: 10px 15px;
            border-radius: 20px;
            cursor: pointer;
            font-size: 0.9em;
            transition: all 0.3s ease;
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
        }
        
        .toggle-btn.active {
            background: linear-gradient(135deg, #667eea, #764ba2);
            transform: translateY(-1px);
            box-shadow: 0 4px 15px rgba(0,0,0,0.2);
        }
        
        .toggle-btn:hover {
            transform: translateY(-1px);
            box-shadow: 0 4px 15px rgba(0,0,0,0.2);
        }
        
        .secondary-controls {
            display: flex;
            justify-content: center;
            gap: 10px;
            margin-top: 15px;
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
            <div class="secondary-controls">
                <button class="toggle-btn" id="shuffleBtn" onclick="toggleShuffle()">🔀 Shuffle</button>
                <button class="toggle-btn" id="repeatBtn" onclick="toggleRepeat()">🔁 Repeat</button>
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
        let isShuffleEnabled = false;
        let repeatMode = 0; // 0: off, 1: repeat all, 2: repeat one
        let shuffledIndices = [];
        let shufflePosition = 0;
        
        const audioPlayer = document.getElementById('audioPlayer');
        const currentSongElement = document.getElementById('currentSong');
        const songList = document.getElementById('songList');
        const shuffleBtn = document.getElementById('shuffleBtn');
        const repeatBtn = document.getElementById('repeatBtn');
        
        // Initialize shuffle indices
        function generateShuffledIndices() {
            shuffledIndices = Array.from({length: songs.length}, (_, i) => i);
            for (let i = shuffledIndices.length - 1; i > 0; i--) {
                const j = Math.floor(Math.random() * (i + 1));
                [shuffledIndices[i], shuffledIndices[j]] = [shuffledIndices[j], shuffledIndices[i]];
            }
            shufflePosition = 0;
        }
        
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
            
            if (repeatMode === 2) { // Repeat one
                // Just replay the current song
                const song = songs[currentSongIndex];
                playSong(song.filename, song.title, currentSongIndex);
                return;
            }
            
            if (isShuffleEnabled) {
                shufflePosition = (shufflePosition + 1) % shuffledIndices.length;
                currentSongIndex = shuffledIndices[shufflePosition];
            } else {
                currentSongIndex = (currentSongIndex + 1) % songs.length;
            }
            
            const song = songs[currentSongIndex];
            playSong(song.filename, song.title, currentSongIndex);
        }
        
        function previousSong() {
            if (songs.length === 0) return;
            
            if (isShuffleEnabled) {
                shufflePosition = shufflePosition <= 0 ? shuffledIndices.length - 1 : shufflePosition - 1;
                currentSongIndex = shuffledIndices[shufflePosition];
            } else {
                currentSongIndex = currentSongIndex <= 0 ? songs.length - 1 : currentSongIndex - 1;
            }
            
            const song = songs[currentSongIndex];
            playSong(song.filename, song.title, currentSongIndex);
        }
        
        function toggleShuffle() {
            isShuffleEnabled = !isShuffleEnabled;
            shuffleBtn.classList.toggle('active', isShuffleEnabled);
            
            if (isShuffleEnabled) {
                generateShuffledIndices();
                // Find current song in shuffle order
                shufflePosition = shuffledIndices.indexOf(currentSongIndex);
                shuffleBtn.textContent = '🔀 Shuffle: ON';
            } else {
                shuffleBtn.textContent = '🔀 Shuffle';
            }
        }
        
        function toggleRepeat() {
            repeatMode = (repeatMode + 1) % 3;
            repeatBtn.classList.toggle('active', repeatMode > 0);
            
            switch (repeatMode) {
                case 0:
                    repeatBtn.textContent = '🔁 Repeat';
                    break;
                case 1:
                    repeatBtn.textContent = '🔁 Repeat: ALL';
                    break;
                case 2:
                    repeatBtn.textContent = '🔂 Repeat: ONE';
                    break;
            }
        }
        
        // Enhanced auto-play logic
        function handleSongEnd() {
            if (repeatMode === 0 && !isShuffleEnabled && currentSongIndex === songs.length - 1) {
                // Stop at end if no repeat and no shuffle
                return;
            }
            nextSong();
        }
        
        // Auto-play next song when current song ends
        audioPlayer.addEventListener('ended', handleSongEnd);
        
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
    # Check if it's a local uploaded file first
    if localFiles.hasKey(filename):
      try:
        # Decode base64 content
        return decode(localFiles[filename])
      except:
        echo "Failed to decode local file: ", filename
        return ""
    
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
      # Check cache first
      if musicCache.hasKey(filename):
        echo "🎯 Cache HIT for: ", filename, " (", cacheHits + 1, " hits, ", cacheMisses, " misses)"
        inc(cacheHits)
        return musicCache[filename]
      
      echo "💾 Cache MISS for: ", filename, " - fetching from GitHub..."
      inc(cacheMisses)
      
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
                let fileContent = await blobResponse.body
                echo "✅ Successfully fetched file via GitHub blobs API (", fileContent.len, " bytes)"
                
                # Cache the file content
                musicCache[filename] = fileContent
                echo "💾 Cached file: ", filename, " (cache size: ", musicCache.len, " files)"
                
                return fileContent
              else:
                echo "❌ Failed to fetch blob: ", blobResponse.status
                return ""
            else:
              echo "⚠️  No SHA available for file: ", filename
              return ""
            
      except Exception as e:
        echo "💥 Error streaming file via GitHub API: ", e.msg
        return ""
      
      echo "🔍 Song not found: ", filename
      return ""

proc serveStaticFile(filePath: string): Future[string] {.async, gcsafe.} =
  {.cast(gcsafe).}:
    try:
      if fileExists(filePath):
        result = readFile(filePath)
      else:
        result = ""
    except:
      result = ""

proc getStaticMimeType(filename: string): string =
  let ext = splitFile(filename).ext.toLowerAscii()
  case ext
  of ".html": "text/html"
  of ".css": "text/css"
  of ".js": "application/javascript"
  of ".json": "application/json"
  of ".png": "image/png"
  of ".jpg", ".jpeg": "image/jpeg"
  of ".gif": "image/gif"
  of ".svg": "image/svg+xml"
  of ".ico": "image/x-icon"
  else: "text/plain"

proc handleRequest(req: Request) {.async, gcsafe.} =
  {.cast(gcsafe).}:
    let path = req.url.path
    
    try:
      if path == "/" or path == "":
        # Serve main page from public directory
        let indexPath = "public/index.html"
        let content = await serveStaticFile(indexPath)
        if content != "":
          await req.respond(Http200, content, newHttpHeaders([("Content-Type", "text/html")]))
        else:
          await req.respond(Http404, "index.html not found")
      
      elif path.startsWith("/public/") or path.startsWith("/static/"):
        # Serve static files (CSS, JS, etc.)
        let cleanPath = path.replace("/public/", "").replace("/static/", "")
        let filePath = "public/" & cleanPath
        let content = await serveStaticFile(filePath)
        
        if content != "":
          let mimeType = getStaticMimeType(cleanPath)
          await req.respond(Http200, content, newHttpHeaders([("Content-Type", mimeType)]))
        else:
          await req.respond(Http404, "Static file not found")
      
      elif path == "/style.css":
        # Direct access to CSS
        let content = await serveStaticFile("public/style.css")
        if content != "":
          await req.respond(Http200, content, newHttpHeaders([("Content-Type", "text/css")]))
        else:
          await req.respond(Http404, "CSS file not found")
      
      elif path == "/app.js":
        # Direct access to JS
        let content = await serveStaticFile("public/app.js")
        if content != "":
          await req.respond(Http200, content, newHttpHeaders([("Content-Type", "application/javascript")]))
        else:
          await req.respond(Http404, "JS file not found")
      
      elif path.startsWith("/music/"):
        # Stream audio file (updated endpoint)
        let filename = decodeUrl(path.replace("/music/", ""))
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
      
      elif path.startsWith("/stream/"):
        # Legacy stream endpoint for compatibility
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
      
      elif path == "/api/songs":
        # Return songs list as JSON with format information
        let source = getMusicSource()
        let songs = if source == msGitHub:
          waitFor fetchSongsFromGitHub()
        else:
          scanMusicDirectory(MUSIC_DIR)
          
        let songData = songs.mapIt(%*{
          "filename": it.filename,
          "title": it.title,
          "format": it.format
        })
        let response = %songData
        await req.respond(Http200, $response, newHttpHeaders([("Content-Type", "application/json")]))
      
      elif path == "/api/cache-stats":
        # Return cache statistics
        let stats = getCacheStats()
        let jsonStats = %*{
          "cached_files": musicCache.len,
          "cache_hits": cacheHits,
          "cache_misses": cacheMisses,
          "hit_rate": if (cacheHits + cacheMisses) > 0: (cacheHits.float / (cacheHits + cacheMisses).float) * 100.0 else: 0.0,
          "message": stats
        }
        await req.respond(Http200, $jsonStats, newHttpHeaders([("Content-Type", "application/json")]))
      
      elif path == "/api/clear-cache":
        # Clear the cache
        clearCache()
        let response = %*{"message": "Cache cleared successfully"}
        await req.respond(Http200, $response, newHttpHeaders([("Content-Type", "application/json")]))
      
      elif path == "/api/favorites":
        if req.reqMethod == HttpGet:
          # Get favorites
          let response = %userFavorites
          await req.respond(Http200, $response, newHttpHeaders([("Content-Type", "application/json")]))
        elif req.reqMethod == HttpPost:
          # Add/remove favorite
          let body = req.body
          try:
            let jsonData = parseJson(body)
            let songName = jsonData["song"].getStr()
            let action = jsonData["action"].getStr()
            
            if action == "add" and songName notin userFavorites:
              userFavorites.add(songName)
            elif action == "remove":
              userFavorites = userFavorites.filterIt(it != songName)
            
            let response = %*{"message": "Favorites updated", "favorites": userFavorites}
            await req.respond(Http200, $response, newHttpHeaders([("Content-Type", "application/json")]))
          except:
            await req.respond(Http400, "Invalid JSON")
        else:
          await req.respond(Http405, "Method not allowed")
      
      elif path == "/api/config":
        # Get current configuration
        if req.reqMethod == HttpGet:
          let musicSource = getMusicSource()
          let currentDir = getCurrentDir()
          let musicDir = currentDir / MUSIC_DIR
          
          let sourceText = case musicSource
            of msLocal: "Local"
            of msGitHub: "GitHub"
            of msGitLab: "GitLab"
            of msGitRepo: "Git Repository"
          
          let response = %*{
            "source": sourceText,
            "directory": musicDir,
            "relativeDirectory": MUSIC_DIR
          }
          await req.respond(Http200, $response, newHttpHeaders([("Content-Type", "application/json")]))
        else:
          await req.respond(Http405, "Method not allowed")
      
      elif path == "/api/playlists":
        if req.reqMethod == HttpGet:
          # Get all playlists
          let response = %userPlaylists
          await req.respond(Http200, $response, newHttpHeaders([("Content-Type", "application/json")]))
        elif req.reqMethod == HttpPost:
          # Create/update playlist
          try:
            let body = req.body
            let jsonData = parseJson(body)
            let playlistName = jsonData["name"].getStr()
            let songs = jsonData["songs"].getElems().mapIt(it.getStr())
            
            # Store in memory
            userPlaylists[playlistName] = songs
            
            # Always save playlists locally regardless of music source
            echo "🔍 Debug - Saving playlist locally..."
            let playlistsDir = "playlists"
            if not dirExists(playlistsDir):
              createDir(playlistsDir)
            
            let playlistData = %*{
              "name": playlistName,
              "songs": songs,
              "created": $now(),
              "type": "playlist"
            }
            
            let playlistFile = playlistsDir / (playlistName & ".json")
            writeFile(playlistFile, $playlistData)
            echo "🔍 Debug - Playlist saved locally to: ", playlistFile
            
            let response = %*{"message": "Playlist saved", "name": playlistName}
            await req.respond(Http200, $response, newHttpHeaders([("Content-Type", "application/json")]))
          except:
            await req.respond(Http400, "Invalid playlist data")
        else:
          await req.respond(Http405, "Method not allowed")
      
      elif path.startsWith("/api/playlists/"):
        # Handle individual playlist operations
        let playlistName = path[15..^1].decodeUrl()  # Remove "/api/playlists/" prefix
        if req.reqMethod == HttpDelete:
          # Delete playlist
          if userPlaylists.hasKey(playlistName):
            userPlaylists.del(playlistName)
            
            # Delete local playlist file
            echo "🔍 Debug - Deleting local playlist file..."
            let playlistFile = "playlists" / (playlistName & ".json")
            if fileExists(playlistFile):
              removeFile(playlistFile)
              echo "🔍 Debug - Local playlist file deleted: ", playlistFile
            
            let response = %*{"message": "Playlist deleted", "name": playlistName}
            await req.respond(Http200, $response, newHttpHeaders([("Content-Type", "application/json")]))
          else:
            await req.respond(Http404, "Playlist not found")
        else:
          await req.respond(Http405, "Method not allowed")
      
      else:
        await req.respond(Http404, "Not found")
        
    except Exception as e:
      echo "Error handling request: ", e.msg
      await req.respond(Http500, "Internal server error")

proc main() {.async.} =
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
  
  # Always load local playlists regardless of music source
  loadLocalPlaylists()
  
  let serverPort = getServerPort()
  echo "Server starting on http://0.0.0.0:", serverPort
  
  let songs = scanMusicDirectory(MUSIC_DIR)
  echo "🎶 Found ", songs.len, " music files"
  echo "💾 Music cache initialized (will cache files on first access)"
  
  # Load playlists from GitHub if configured
  if source == msGitHub:
    echo "🔍 Loading playlists from GitHub..."
    try:
      # Load playlists and assign to global variable
      let loadedPlaylists = waitFor fetchPlaylistsFromGitHub()
      {.cast(gcsafe).}:
        userPlaylists = loadedPlaylists
      echo "📋 Loaded ", userPlaylists.len, " playlists from GitHub"
    except Exception as e:
      echo "📋 Failed to load playlists from GitHub: ", e.msg
      echo "📋 Will load on demand"
  
  echo "🌐 Open http://localhost:", serverPort, " in your browser"
  echo "⌨️  Keyboard shortcuts: Space (play/pause), ← → (prev/next)"
  echo "🛑 Press Ctrl+C to stop the server"
  
  server.listen(Port(serverPort), "0.0.0.0")
  
  while true:
    if server.shouldAcceptRequest():
      await server.acceptRequest(handleRequest)
    else:
      await sleepAsync(1)

when isMainModule:
  waitFor main()