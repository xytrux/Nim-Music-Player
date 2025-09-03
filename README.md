# Nim Music Player 🎵

A personal music streaming server built with Nim that can serve music from **Git repositories**! Perfect for Railway deployment with private music collections.

## ✨ Features

- 🎵 Supports FLAC, MP3, WAV, OGG, and M4A formats
- 🔒 **Private Git repository music source** (GitHub/GitLab)
- 🚀 Railway deployment ready
- 🎨 Beautiful, responsive web interface
- ⌨️ Keyboard controls (Space, Arrow keys)
- 🔄 Auto-play next track
- 📱 Mobile-friendly design

## 🚀 Quick Setup for Railway

### Step 1: Create a Private Music Repository

1. Create a **private repository** on GitHub or GitLab
2. Create a `music` folder and upload your music files
3. Generate an access token:
   - **GitHub**: Go to Settings → Developer settings → Personal access tokens → Tokens (classic)
   - **GitLab**: Go to Profile → Access Tokens

### Step 2: Deploy to Railway

1. Fork this repository
2. Connect it to Railway
3. Set these environment variables in Railway:

```bash
MUSIC_SOURCE=github
GIT_REPO_URL=yourusername/your-private-music-repo
GIT_TOKEN=your_github_token_here
GIT_BRANCH=main
GIT_MUSIC_PATH=music
```

### Step 3: Deploy! 🎉

Railway will automatically build and deploy your music player!

## 🔧 Configuration Options

### GitHub Private Repository
```bash
MUSIC_SOURCE=github
GIT_REPO_URL=xytrux/my-music-collection
GIT_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxx
GIT_BRANCH=main
GIT_MUSIC_PATH=music
```

### GitLab Private Repository
```bash
MUSIC_SOURCE=gitlab
GIT_REPO_URL=https://gitlab.com/username/music-repo
GIT_TOKEN=glpat-xxxxxxxxxxxxxxxxxxxx
GIT_BRANCH=main
GIT_MUSIC_PATH=audio
```

### Public Repository (Demo Mode)
```bash
MUSIC_SOURCE=github
GIT_REPO_URL=username/public-music-demos
# No token needed for public repos
```

### Local Development
```bash
MUSIC_SOURCE=local
# Uses ./music directory
```

## 💡 Why This Approach is Perfect

### ✅ **Copyright Safe**
- Your music stays in a **private repository**
- Only you have access to the actual files
- This public repo contains zero copyrighted content

### ✅ **Railway Compatible**
- No persistent storage needed
- Streams directly from Git
- Free private repositories on GitHub/GitLab

### ✅ **Version Controlled Music**
- Track changes to your music collection
- Organize with Git branches (genres, albums, etc.)
- Easy backup and sync across devices

### ✅ **Scalable & Fast**
- Git providers have excellent CDNs
- Automatic caching
- Works globally

## 🛠️ Local Development

1. Clone this repository:
```bash
git clone https://github.com/xytrux/nim-music-player.git
cd nim-music-player
```

2. Set up environment variables:
```bash
cp .env.example .env
# Edit .env with your Git repository details
```

3. Run the server:
```bash
nim c -r src/main.nim
```

4. Open `http://localhost:8080`

## 📁 Music Repository Structure

Your private music repository should look like:
```
your-music-repo/
├── music/
│   ├── 01 - Song One.flac
│   ├── 02 - Song Two.mp3
│   ├── 03 - Song Three.wav
│   └── ...
├── README.md
└── .gitignore
```

## 🔐 Security Best Practices

1. **Always use private repositories** for your music
2. **Use personal access tokens** with minimal permissions
3. **Never commit tokens** to version control
4. **Consider token rotation** periodically
5. **Use environment variables** for all sensitive data

## 🎯 Perfect Use Cases

- **Personal music streaming** from anywhere
- **Demo applications** with sample tracks
- **Music sharing** with specific people (repo collaborators)
- **Backup music player** that works on any device
- **Portfolio projects** with royalty-free demo music

## 📝 Legal Notice

This software is designed for personal use with music you own or have proper licensing for. Users are responsible for ensuring they have the rights to stream any music files. Using private repositories helps ensure your copyrighted content stays private.

## 🤝 Contributing

Feel free to submit issues and enhancement requests!

## 📄 License

MIT License - See LICENSE file for details

---

**🎵 Enjoy your music, anywhere, anytime! 🎵**
