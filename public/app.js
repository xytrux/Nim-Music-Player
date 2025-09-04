class MusicPlayer {
    constructor() {
        this.currentSong = null;
        this.currentIndex = 0;
        this.songs = [];
        this.isPlaying = false;
        this.isShuffling = false;
        this.repeatMode = 'off'; // 'off', 'all', 'one'
        this.audioPlayer = null;
        this.favorites = new Set(JSON.parse(localStorage.getItem('favorites') || '[]'));
        this.currentSection = 'music';
        this.playlists = {};
        this.uploadedFiles = [];
        this.currentSongToAdd = null;
        this.selectedPlaylistForAdd = null;
        this.addSongAfterCreate = null;
        this.playlistToDelete = null;
        
        this.init();
        this.loadSongs();
        this.loadCacheStats();
        this.startPeriodicUpdates();
    }

    init() {
        this.audioPlayer = document.getElementById('audio-player');
        this.setupEventListeners();
        this.setupAudioEvents();
        this.setupNavigation();
        this.setupUpload();
        this.setupProgressBar();
        this.setupVolumeControl();
        this.loadPlaylists();
    }

    setupNavigation() {
        const navItems = document.querySelectorAll('.nav-item[data-section]');
        navItems.forEach(item => {
            item.addEventListener('click', () => {
                const section = item.dataset.section;
                this.switchSection(section);
                
                // Update active nav item
                navItems.forEach(nav => nav.classList.remove('active'));
                item.classList.add('active');
            });
        });

        // Clear cache button
        document.getElementById('clear-cache-btn').addEventListener('click', () => {
            this.clearCache();
        });

        // Create playlist button
        document.getElementById('create-playlist-btn').addEventListener('click', () => {
            this.createNewPlaylist();
        });
    }

    setupUpload() {
        // No upload functionality - just show instructions
        // Update current config display
        this.updateConfigDisplay();
    }

    async updateConfigDisplay() {
        try {
            const response = await fetch('/api/config');
            if (response.ok) {
                const config = await response.json();
                
                const sourceElement = document.getElementById('current-source');
                const directoryElement = document.getElementById('current-directory');
                const pathElement = document.getElementById('music-directory-path');
                
                if (sourceElement) {
                    sourceElement.textContent = config.source;
                }
                
                if (directoryElement) {
                    directoryElement.textContent = config.relativeDirectory;
                }
                
                if (pathElement) {
                    pathElement.textContent = config.directory;
                }
            }
        } catch (error) {
            console.error('Failed to load config:', error);
            // Fallback values
            const sourceElement = document.getElementById('current-source');
            const directoryElement = document.getElementById('current-directory');
            const pathElement = document.getElementById('music-directory-path');
            
            if (sourceElement) sourceElement.textContent = 'Local';
            if (directoryElement) directoryElement.textContent = './music';
            if (pathElement) pathElement.textContent = './music';
        }
    }

    formatFileSize(bytes) {
        if (bytes === 0) return '0 Bytes';
        const k = 1024;
        const sizes = ['Bytes', 'KB', 'MB', 'GB'];
        const i = Math.floor(Math.log(bytes) / Math.log(k));
        return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
    }

    async loadPlaylists() {
        try {
            const response = await fetch('/api/playlists');
            this.playlists = await response.json();
            this.updatePlaylistsView();
        } catch (error) {
            console.error('Failed to load playlists:', error);
        }
    }

    updatePlaylistsView() {
        const playlistsGrid = document.getElementById('playlists-grid');
        const sidebarPlaylists = document.getElementById('sidebar-playlists');
        const playlistNames = Object.keys(this.playlists);
        
        // Update main playlists grid
        if (playlistNames.length === 0) {
            playlistsGrid.innerHTML = `
                <div class="empty-state">
                    <div class="empty-state-icon">
                        <svg width="48" height="48" viewBox="0 0 24 24" fill="currentColor">
                            <path d="M3 13h2v-2H3v2zm0 4h2v-2H3v2zm0-8h2V7H3v2zm4 4h14v-2H7v2zm0 4h14v-2H7v2zM7 7v2h14V7H7z"/>
                        </svg>
                    </div>
                    <div class="empty-state-title">No playlists yet</div>
                    <div class="empty-state-description">
                        Create your first playlist or upload M3U files.
                    </div>
                </div>
            `;
        } else {
            playlistsGrid.innerHTML = playlistNames.map(name => {
                const songCount = this.playlists[name].length;
                return `
                    <div class="playlist-card" onclick="window.musicPlayer.openPlaylist('${name}')">
                        <div class="playlist-card-icon">
                            <svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor">
                                <path d="M3 13h2v-2H3v2zm0 4h2v-2H3v2zm0-8h2V7H3v2zm4 4h14v-2H7v2zm0 4h14v-2H7v2zM7 7v2h14V7H7z"/>
                            </svg>
                        </div>
                        <div class="playlist-card-title">${name}</div>
                        <div class="playlist-card-count">${songCount} songs</div>
                        <button class="playlist-delete-btn" onclick="event.stopPropagation(); window.musicPlayer.deletePlaylist('${name}')" title="Delete playlist">
                            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                                <polyline points="3,6 5,6 21,6"></polyline>
                                <path d="M19,6V20a2,2 0 0,1-2,2H7a2,2 0 0,1-2-2V6M8,6V4a2,2 0 0,1,2-2h4a2,2 0 0,1,2,2V6"></path>
                                <line x1="10" y1="11" x2="10" y2="17"></line>
                                <line x1="14" y1="11" x2="14" y2="17"></line>
                            </svg>
                        </button>
                    </div>
                `;
            }).join('');
        }

        // Update sidebar playlists
        if (playlistNames.length === 0) {
            sidebarPlaylists.innerHTML = '';
        } else {
            sidebarPlaylists.innerHTML = playlistNames.map(name => {
                const songCount = this.playlists[name].length;
                const isActive = this.currentPlaylist === name ? 'active' : '';
                return `
                    <div class="sidebar-playlist-item ${isActive}" onclick="window.musicPlayer.openPlaylist('${name}')" title="${name} (${songCount} songs)">
                        <svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor">
                            <path d="M3 13h2v-2H3v2zm0 4h2v-2H3v2zm0-8h2V7H3v2zm4 4h14v-2H7v2zm0 4h14v-2H7v2zM7 7v2h14V7H7z"/>
                        </svg>
                        <span>${name.length > 12 ? name.substring(0, 12) + '...' : name}</span>
                        <button class="playlist-delete" onclick="event.stopPropagation(); window.musicPlayer.deletePlaylist('${name}')" title="Delete playlist">
                            <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                                <line x1="18" y1="6" x2="6" y2="18"></line>
                                <line x1="6" y1="6" x2="18" y2="18"></line>
                            </svg>
                        </button>
                    </div>
                `;
            }).join('');
        }
    }

    createNewPlaylist() {
        this.showModal('create-playlist-modal');
        document.getElementById('playlist-name-input').focus();
    }

    // Modal management methods
    showModal(modalId) {
        const modal = document.getElementById(modalId);
        modal.classList.add('active');
        document.body.style.overflow = 'hidden';
    }

    closeModal(modalId) {
        const modal = document.getElementById(modalId);
        modal.classList.remove('active');
        document.body.style.overflow = '';
        
        // Clear form inputs
        if (modalId === 'create-playlist-modal') {
            document.getElementById('playlist-name-input').value = '';
        }
        if (modalId === 'add-to-playlist-modal') {
            this.currentSongToAdd = null;
            this.selectedPlaylistForAdd = null;
        }
    }

    confirmCreatePlaylist() {
        const nameInput = document.getElementById('playlist-name-input');
        const name = nameInput.value.trim();
        
        if (!name) {
            nameInput.focus();
            return;
        }
        
        if (this.playlists[name]) {
            this.showNotification('A playlist with this name already exists', 'error');
            return;
        }
        
        // If we have a song to add after creating
        const songs = this.addSongAfterCreate ? [this.addSongAfterCreate] : [];
        
        this.savePlaylist(name, songs);
        
        if (this.addSongAfterCreate) {
            this.showNotification(`Playlist "${name}" created and song added`, 'success');
            this.addSongAfterCreate = null;
        } else {
            this.showNotification(`Playlist "${name}" created`, 'success');
        }
        
        this.closeModal('create-playlist-modal');
        nameInput.value = '';
    }

    async savePlaylist(name, songs) {
        try {
            const response = await fetch('/api/playlists', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ name, songs })
            });

            if (response.ok) {
                this.playlists[name] = songs;
                this.updatePlaylistsView();
                this.showNotification(`Success: Playlist "${name}" saved`, 'success');
            }
        } catch (error) {
            console.error('Failed to save playlist:', error);
            this.showNotification('Error: Failed to save playlist', 'error');
        }
    }

    async deletePlaylist(name) {
        this.playlistToDelete = name;
        document.getElementById('delete-playlist-text').textContent = 
            `Are you sure you want to delete the playlist "${name}"?`;
        this.showModal('delete-playlist-modal');
    }

    async confirmDeletePlaylist() {
        const name = this.playlistToDelete;
        if (!name) return;

        try {
            const response = await fetch(`/api/playlists/${encodeURIComponent(name)}`, {
                method: 'DELETE'
            });

            if (response.ok) {
                delete this.playlists[name];
                
                // If we're currently viewing this playlist, go back to main view
                if (this.currentPlaylist === name) {
                    this.exitPlaylist();
                }
                
                this.updatePlaylistsView();
                this.showNotification(`Playlist "${name}" deleted`, 'success');
            } else {
                console.error('Delete failed with status:', response.status);
                this.showNotification(`Error: Failed to delete playlist (${response.status})`, 'error');
            }
        } catch (error) {
            console.error('Failed to delete playlist:', error);
            this.showNotification('Error: Failed to delete playlist', 'error');
        }
        
        this.closeModal('delete-playlist-modal');
        this.playlistToDelete = null;
    }

    openPlaylist(name) {
        // Set current playlist state
        this.currentPlaylist = name;
        this.playlistSongs = this.playlists[name] || [];
        
        // Switch to music section to show the playlist
        this.switchToSection('music');
        
        // Update the page title
        document.querySelector('.page-title').textContent = `Playlist: ${name}`;
        
        // Add a back button to the page actions
        const pageActions = document.querySelector('.page-actions');
        pageActions.innerHTML = `
            <button class="control-btn back-btn" onclick="window.musicPlayer.exitPlaylist()">
                <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor">
                    <path d="M20 11H7.83l5.59-5.59L12 4l-8 8 8 8 1.41-1.41L7.83 13H20v-2z"/>
                </svg>
                Back to Library
            </button>
        `;
        
        // Update the song list to show only playlist songs
        this.renderPlaylistView(name);
        
        // Update sidebar to show active playlist
        this.updateSidebarPlaylistStates();
    }

    exitPlaylist() {
        // Reset playlist state
        this.currentPlaylist = null;
        this.playlistSongs = [];
        
        // Reset page title
        document.querySelector('.page-title').textContent = 'Your Music';
        
        // Clear page actions
        document.querySelector('.page-actions').innerHTML = '';
        
        // Re-render the normal song list
        this.renderSongList();
        
        // Update sidebar to remove active playlist
        this.updateSidebarPlaylistStates();
    }

    updateSidebarPlaylistStates() {
        const sidebarPlaylistItems = document.querySelectorAll('.sidebar-playlist-item');
        sidebarPlaylistItems.forEach(item => {
            item.classList.remove('active');
            if (this.currentPlaylist && item.textContent.trim().startsWith(this.currentPlaylist)) {
                item.classList.add('active');
            }
        });
    }

    renderPlaylistView(playlistName) {
        const songList = document.getElementById('song-list');
        const playlistSongs = this.playlists[playlistName] || [];
        
        if (playlistSongs.length === 0) {
            songList.innerHTML = `
                <div class="empty-state">
                    <div class="empty-state-icon">
                        <svg width="48" height="48" viewBox="0 0 24 24" fill="currentColor">
                            <path d="M3 13h2v-2H3v2zm0 4h2v-2H3v2zm0-8h2V7H3v2zm4 4h14v-2H7v2zm0 4h14v-2H7v2zM7 7v2h14V7H7z"/>
                        </svg>
                    </div>
                    <div class="empty-state-title">Empty playlist</div>
                    <div class="empty-state-description">
                        Add songs to this playlist using the + button next to any song.
                    </div>
                </div>
            `;
            return;
        }

        // Render playlist songs with remove option
        songList.innerHTML = playlistSongs.map((song, index) => {
            const originalIndex = this.songs.indexOf(song);
            return `
                <li class="song-item" data-index="${originalIndex}" data-playlist-song="${song}">
                    <div class="song-number">${String(index + 1).padStart(2, '0')}</div>
                    <div class="song-title">${this.formatSongTitle(song)}</div>
                    <div class="song-actions">
                        <button class="favorite-btn ${this.favorites.has(song) ? 'favorited' : ''}" 
                                data-song="${song}" title="Add to favorites">
                            <svg width="16" height="16" viewBox="0 0 24 24" fill="${this.favorites.has(song) ? 'var(--accent-color)' : 'none'}" stroke="currentColor" stroke-width="2">
                                <path d="M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z"/>
                            </svg>
                        </button>
                        <button class="remove-from-playlist-btn" 
                                data-song="${song}" data-playlist="${playlistName}" title="Remove from playlist">
                            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                                <path d="M6 18L18 6M6 6l12 12"/>
                            </svg>
                        </button>
                        <div class="song-format">FLAC</div>
                    </div>
                </li>
            `;
        }).join('');

        // Add click listeners for playlist view
        songList.addEventListener('click', (e) => {
            const songItem = e.target.closest('.song-item');
            if (songItem) {
                if (e.target.closest('.remove-from-playlist-btn')) {
                    const song = e.target.closest('.remove-from-playlist-btn').dataset.song;
                    const playlist = e.target.closest('.remove-from-playlist-btn').dataset.playlist;
                    this.removeFromPlaylist(song, playlist);
                } else if (!e.target.closest('.favorite-btn')) {
                    const index = parseInt(songItem.dataset.index);
                    this.playSong(index);
                }
            }
        });
    }

    removeFromPlaylist(song, playlistName) {
        const currentSongs = this.playlists[playlistName] || [];
        const updatedSongs = currentSongs.filter(s => s !== song);
        
        this.savePlaylist(playlistName, updatedSongs);
        this.renderPlaylistView(playlistName);
        this.showNotification(`Song removed from playlist "${playlistName}"`, 'success');
    }

    switchToSection(sectionName) {
        // Hide all sections
        document.querySelectorAll('.content-section').forEach(section => {
            section.classList.add('hidden');
        });
        
        // Remove active class from all nav items
        document.querySelectorAll('.nav-item').forEach(item => {
            item.classList.remove('active');
        });
        
        // Show the requested section
        const targetSection = document.getElementById(`${sectionName}-section`);
        if (targetSection) {
            targetSection.classList.remove('hidden');
        }
        
        // Add active class to the corresponding nav item
        const navItem = document.querySelector(`[data-section="${sectionName}"]`);
        if (navItem) {
            navItem.classList.add('active');
        }
    }

    showAddToPlaylistDialog(song) {
        this.currentSongToAdd = song;
        this.selectedPlaylistForAdd = null;
        
        const playlistNames = Object.keys(this.playlists);
        
        if (playlistNames.length === 0) {
            // No playlists exist, show create playlist modal
            this.showModal('create-playlist-modal');
            document.getElementById('playlist-name-input').focus();
            // Set a flag so we know to add the song after creating the playlist
            this.addSongAfterCreate = song;
            return;
        }

        // Update the modal text
        document.getElementById('add-song-text').textContent = 
            `Add "${this.formatSongTitle(song)}" to a playlist:`;
        
        // Populate playlist options
        const playlistSelection = document.getElementById('playlist-selection');
        playlistSelection.innerHTML = playlistNames.map(name => {
            const songCount = this.playlists[name].length;
            return `
                <div class="playlist-option" data-playlist="${name}">
                    <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor">
                        <path d="M3 13h2v-2H3v2zm0 4h2v-2H3v2zm0-8h2V7H3v2zm4 4h14v-2H7v2zm0 4h14v-2H7v2zM7 7v2h14V7H7z"/>
                    </svg>
                    <div>
                        <div style="font-weight: 500;">${name}</div>
                        <div style="font-size: 12px; color: var(--text-muted);">${songCount} songs</div>
                    </div>
                </div>
            `;
        }).join('');
        
        // Add click listeners to playlist options
        playlistSelection.querySelectorAll('.playlist-option').forEach(option => {
            option.addEventListener('click', () => {
                // Remove previous selection
                playlistSelection.querySelectorAll('.playlist-option').forEach(opt => 
                    opt.classList.remove('selected'));
                
                // Select this option
                option.classList.add('selected');
                this.selectedPlaylistForAdd = option.dataset.playlist;
                
                // Enable the add button
                document.getElementById('add-to-playlist-btn').disabled = false;
            });
        });
        
        // Disable the add button initially
        document.getElementById('add-to-playlist-btn').disabled = true;
        
        this.showModal('add-to-playlist-modal');
    }

    showCreatePlaylistFromAdd() {
        this.closeModal('add-to-playlist-modal');
        this.showModal('create-playlist-modal');
        this.addSongAfterCreate = this.currentSongToAdd;
        document.getElementById('playlist-name-input').focus();
    }

    confirmAddToPlaylist() {
        if (!this.selectedPlaylistForAdd || !this.currentSongToAdd) return;
        
        const playlistName = this.selectedPlaylistForAdd;
        const song = this.currentSongToAdd;
        const currentSongs = this.playlists[playlistName] || [];
        
        if (currentSongs.includes(song)) {
            this.showNotification(`Song is already in playlist "${playlistName}"`, 'warning');
        } else {
            const updatedSongs = [...currentSongs, song];
            this.savePlaylist(playlistName, updatedSongs);
            this.showNotification(`Song added to playlist "${playlistName}"`, 'success');
        }
        
        this.closeModal('add-to-playlist-modal');
    }

    setupProgressBar() {
        const progressWrapper = document.querySelector('.progress-wrapper');
        const progressTrack = document.getElementById('progress-track');
        const progressPlayed = document.getElementById('progress-played');
        const progressThumb = document.getElementById('progress-thumb');
        const currentTimeEl = document.getElementById('current-time');
        const totalTimeEl = document.getElementById('total-time');

        console.log('🎯 Setting up NEW progress bar system:', {
            progressWrapper: !!progressWrapper,
            progressTrack: !!progressTrack,
            progressPlayed: !!progressPlayed,
            progressThumb: !!progressThumb,
            currentTimeEl: !!currentTimeEl,
            totalTimeEl: !!totalTimeEl
        });

        if (!progressWrapper || !progressTrack || !progressPlayed || !progressThumb || !currentTimeEl || !totalTimeEl) {
            console.error('❌ Missing critical progress bar elements!');
            return;
        }

        let isDragging = false;

        // Function to update progress display
        const updateProgress = () => {
            if (!this.audioPlayer.duration || isNaN(this.audioPlayer.duration) || this.audioPlayer.duration <= 0) {
                return;
            }

            const currentTime = this.audioPlayer.currentTime || 0;
            const duration = this.audioPlayer.duration;
            const progress = Math.max(0, Math.min(100, (currentTime / duration) * 100));

            // Update visual elements
            progressPlayed.style.width = `${progress}%`;
            progressThumb.style.left = `${progress}%`;

            // Update time displays
            currentTimeEl.textContent = this.formatTime(currentTime);
            totalTimeEl.textContent = this.formatTime(duration);

            // Debug logging - but throttle it
            if (Math.floor(currentTime) % 2 === 0 && Math.floor(currentTime * 10) % 10 === 0) {
                console.log(`🎵 Progress: ${progress.toFixed(1)}% | Fill width: ${progressPlayed.style.width} | Thumb left: ${progressThumb.style.left}`);
                console.log(`⏱️ Time: ${this.formatTime(currentTime)}/${this.formatTime(duration)}`);
            }
        };

        // Function to seek to position
        const seekToPosition = (clientX) => {
            if (!this.audioPlayer.duration || isNaN(this.audioPlayer.duration)) {
                console.log('❌ Cannot seek: no duration');
                return;
            }

            const rect = progressTrack.getBoundingClientRect();
            const percent = Math.max(0, Math.min(1, (clientX - rect.left) / rect.width));
            const newTime = percent * this.audioPlayer.duration;

            console.log(`🎯 Seeking to: ${(percent * 100).toFixed(1)}% = ${this.formatTime(newTime)}`);
            this.audioPlayer.currentTime = newTime;
            updateProgress(); // Immediate visual update
        };

        // Mouse events for clicking
        progressWrapper.addEventListener('mousedown', (e) => {
            isDragging = true;
            seekToPosition(e.clientX);
            e.preventDefault();
        });

        document.addEventListener('mousemove', (e) => {
            if (isDragging) {
                seekToPosition(e.clientX);
                e.preventDefault();
            }
        });

        document.addEventListener('mouseup', () => {
            isDragging = false;
        });

        // Audio events
        this.audioPlayer.addEventListener('timeupdate', updateProgress);

        this.audioPlayer.addEventListener('loadedmetadata', () => {
            console.log('📀 Metadata loaded, duration:', this.formatTime(this.audioPlayer.duration));
            updateProgress();
        });

        this.audioPlayer.addEventListener('canplay', () => {
            console.log('✅ Audio ready to play');
            updateProgress();
        });

        this.audioPlayer.addEventListener('loadstart', () => {
            console.log('🔄 Loading new audio...');
            progressPlayed.style.width = '0%';
            progressThumb.style.left = '0%';
            currentTimeEl.textContent = '0:00';
            totalTimeEl.textContent = '0:00';
        });

        this.audioPlayer.addEventListener('seeking', () => {
            console.log('🔍 Seeking...');
        });

        this.audioPlayer.addEventListener('seeked', () => {
            console.log('✅ Seek completed');
            updateProgress();
        });

        this.audioPlayer.addEventListener('durationchange', () => {
            console.log('⏲️ Duration changed:', this.formatTime(this.audioPlayer.duration));
            updateProgress();
        });

        // Initial setup
        updateProgress();
    }

    setupVolumeControl() {
        const volumeSliderWrapper = document.querySelector('.volume-slider-wrapper');
        const volumeTrack = document.getElementById('volume-track');
        const volumeFill = document.getElementById('volume-fill');
        const volumeHandle = document.getElementById('volume-handle');
        const volumeBtn = document.getElementById('volume-btn');
        const volumeIcon = document.getElementById('volume-icon');
        const volumePercentage = document.getElementById('volume-percentage');

        console.log('🔊 Setting up volume control:', {
            volumeSliderWrapper: !!volumeSliderWrapper,
            volumeTrack: !!volumeTrack,
            volumeFill: !!volumeFill,
            volumeHandle: !!volumeHandle,
            volumeBtn: !!volumeBtn,
            volumeIcon: !!volumeIcon,
            volumePercentage: !!volumePercentage
        });

        if (!volumeSliderWrapper || !volumeFill || !volumeHandle || !volumePercentage) {
            console.error('❌ Missing volume control elements!');
            return;
        }

        // Initialize volume to 100%
        let currentVolume = 1.0;
        let isMuted = false;
        let volumeBeforeMute = 1.0;
        let isDraggingVolume = false;

        // Function to update volume display
        const updateVolumeDisplay = (volume) => {
            const percentage = Math.round(volume * 100);
            volumeFill.style.width = `${percentage}%`;
            volumeHandle.style.left = `${percentage}%`;
            volumePercentage.textContent = `${percentage}%`;

            // Update volume icon based on level
            if (volume === 0 || isMuted) {
                volumeIcon.innerHTML = '<path d="M16.5 12c0-1.77-1.02-3.29-2.5-4.03v2.21l2.45 2.45c.03-.2.05-.41.05-.63zm2.5 0c0 .94-.2 1.82-.54 2.64l1.51 1.51C20.63 14.91 21 13.5 21 12c0-4.28-2.99-7.86-7-8.77v2.06c2.89.86 5 3.54 5 6.71zM4.27 3L3 4.27 7.73 9H3v6h4l5 5v-6.73l4.25 4.25c-.67.52-1.42.93-2.25 1.18v2.06c1.38-.31 2.63-.95 3.69-1.81L19.73 21 21 19.73l-9-9L4.27 3zM12 4L9.91 6.09 12 8.18V4z"/>';
            } else if (volume < 0.5) {
                volumeIcon.innerHTML = '<path d="M18.5 12c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02zM5 9v6h4l5 5V4L9 9H5z"/>';
            } else {
                volumeIcon.innerHTML = '<path d="M3 9v6h4l5 5V4L7 9H3zm13.5 3c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02zM14 3.23v2.06c2.89.86 5 3.54 5 6.71s-2.11 5.85-5 6.71v2.06c4.01-.91 7-4.49 7-8.77s-2.99-7.86-7-8.77z"/>';
            }
        };

        // Function to set volume
        const setVolume = (volume) => {
            currentVolume = Math.max(0, Math.min(1, volume));
            this.audioPlayer.volume = isMuted ? 0 : currentVolume;
            updateVolumeDisplay(currentVolume);
            
            // Save to localStorage
            localStorage.setItem('musicPlayerVolume', currentVolume.toString());
            
            console.log(`🔊 Volume set to: ${Math.round(currentVolume * 100)}%`);
        };

        // Function to toggle mute
        const toggleMute = () => {
            if (isMuted) {
                // Unmute
                isMuted = false;
                setVolume(volumeBeforeMute);
            } else {
                // Mute
                volumeBeforeMute = currentVolume;
                isMuted = true;
                this.audioPlayer.volume = 0;
                updateVolumeDisplay(currentVolume); // Show original volume visually
            }
            
            console.log(`🔊 ${isMuted ? 'Muted' : 'Unmuted'}`);
        };

        // Function to set volume from position
        const setVolumeFromPosition = (clientX) => {
            const rect = volumeTrack.getBoundingClientRect();
            const percent = Math.max(0, Math.min(1, (clientX - rect.left) / rect.width));
            
            if (isMuted && percent > 0) {
                isMuted = false; // Unmute when adjusting volume
            }
            
            setVolume(percent);
        };

        // Mouse events for volume slider
        volumeSliderWrapper.addEventListener('mousedown', (e) => {
            isDraggingVolume = true;
            setVolumeFromPosition(e.clientX);
            e.preventDefault();
        });

        document.addEventListener('mousemove', (e) => {
            if (isDraggingVolume) {
                setVolumeFromPosition(e.clientX);
                e.preventDefault();
            }
        });

        document.addEventListener('mouseup', () => {
            isDraggingVolume = false;
        });

        // Volume button click to toggle volume popup
        volumeBtn.addEventListener('click', (e) => {
            e.stopPropagation();
            const volumePopup = document.getElementById('volume-popup');
            volumePopup.classList.toggle('show');
            
            // Toggle button active state
            volumeBtn.classList.toggle('active');
        });

        // Close volume popup when clicking outside
        document.addEventListener('click', (e) => {
            const volumePopup = document.getElementById('volume-popup');
            if (!volumePopup.contains(e.target) && !volumeBtn.contains(e.target)) {
                volumePopup.classList.remove('show');
                volumeBtn.classList.remove('active');
            }
        });

        // Load saved volume from localStorage
        const savedVolume = localStorage.getItem('musicPlayerVolume');
        if (savedVolume !== null) {
            setVolume(parseFloat(savedVolume));
        } else {
            setVolume(1.0); // Default to 100%
        }

        // Initial display update
        updateVolumeDisplay(currentVolume);
    }

    formatTime(seconds) {
        if (isNaN(seconds)) return '0:00';
        const minutes = Math.floor(seconds / 60);
        const remainingSeconds = Math.floor(seconds % 60);
        return `${minutes}:${remainingSeconds.toString().padStart(2, '0')}`;
    }

    switchSection(section) {
        // Hide all sections
        document.querySelectorAll('.content-section').forEach(sec => {
            sec.classList.add('hidden');
        });

        // Show selected section
        document.getElementById(`${section}-section`).classList.remove('hidden');
        
        // Update page title
        const pageTitle = document.querySelector('.page-title');
        switch(section) {
            case 'music':
                pageTitle.textContent = 'Your Music';
                break;
            case 'upload':
                pageTitle.textContent = 'How to Add Music';
                break;
            case 'cache':
                pageTitle.textContent = 'Cache Statistics';
                this.loadCacheStats();
                break;
            case 'tf2':
                pageTitle.textContent = 'Team Fortress 2';
                this.loadTF2Playlist();
                break;
            case 'favorites':
                pageTitle.textContent = 'Favorites';
                this.loadFavorites();
                break;
        }
        
        this.currentSection = section;
    }

    setupEventListeners() {
        // Control buttons
        document.getElementById('play-pause-btn').addEventListener('click', () => this.togglePlayPause());
        document.getElementById('prev-btn').addEventListener('click', () => this.previousSong());
        document.getElementById('next-btn').addEventListener('click', () => this.nextSong());
        document.getElementById('shuffle-btn').addEventListener('click', () => this.toggleShuffle());
        document.getElementById('repeat-btn').addEventListener('click', () => this.toggleRepeat());
        
        // Song list clicks
        document.getElementById('song-list').addEventListener('click', (e) => {
            const songItem = e.target.closest('.song-item');
            if (songItem) {
                if (e.target.closest('.add-to-playlist-btn')) {
                    const song = e.target.closest('.add-to-playlist-btn').dataset.song;
                    this.showAddToPlaylistDialog(song);
                } else if (!e.target.classList.contains('favorite-btn')) {
                    const index = parseInt(songItem.dataset.index);
                    this.playSong(index);
                }
            }
        });
    }

    setupAudioEvents() {
        this.audioPlayer.addEventListener('loadstart', () => {
            this.showLoadingState();
        });

        this.audioPlayer.addEventListener('canplay', () => {
            this.hideLoadingState();
        });

        this.audioPlayer.addEventListener('play', () => {
            this.isPlaying = true;
            this.updatePlayPauseButton();
        });

        this.audioPlayer.addEventListener('pause', () => {
            this.isPlaying = false;
            this.updatePlayPauseButton();
        });

        this.audioPlayer.addEventListener('ended', () => {
            if (this.repeatMode === 'one') {
                // Repeat current song
                this.audioPlayer.currentTime = 0;
                this.audioPlayer.play();
            } else if (this.repeatMode === 'all') {
                // Go to next song, but loop back to first when reaching end
                this.nextSong();
            } else {
                // No repeat - stop at end of playlist
                if (this.currentIndex < this.songs.length - 1) {
                    this.nextSong();
                } else {
                    this.isPlaying = false;
                    this.updatePlayPauseButton();
                }
            }
        });

        this.audioPlayer.addEventListener('error', (e) => {
            console.error('Audio error:', e);
            this.showError(`Failed to load audio: ${e.target.error?.message || 'Unknown error'}`);
        });
    }

    async loadSongs() {
        try {
            this.showLoadingState();
            const response = await fetch('/api/songs');
            
            if (!response.ok) {
                throw new Error(`HTTP error! status: ${response.status}`);
            }
            
            const newSongs = await response.json();
            
            // Check if songs list has changed
            const songsChanged = JSON.stringify(newSongs) !== JSON.stringify(this.songs);
            
            this.songs = newSongs;
            this.renderSongList();
            this.hideLoadingState();
            
            if (this.songs.length > 0 && !this.currentSong) {
                this.updateNowPlaying(0);
            }
            
            // Update other sections if songs changed
            if (songsChanged) {
                if (this.currentSection === 'tf2') {
                    this.loadTF2Playlist();
                } else if (this.currentSection === 'favorites') {
                    this.loadFavorites();
                }
                
                if (songsChanged && this.songs.length > 0) {
                    this.showNotification(`Music library updated! Found ${this.songs.length} songs`, 'success');
                }
            }
        } catch (error) {
            console.error('Failed to load songs:', error);
            this.showError('Failed to load music library');
        }
    }

    startPeriodicUpdates() {
        // Check for new songs every 30 seconds
        setInterval(() => {
            this.loadSongs();
        }, 30000);
    }

    renderSongList() {
        const songList = document.getElementById('song-list');
        const songCount = document.getElementById('song-count');
        
        if (this.songs.length === 0) {
            songList.innerHTML = `
                                <div class="empty-state">
                    <div class="empty-state-icon">
                        <svg width="48" height="48" viewBox="0 0 24 24" fill="currentColor">
                            <path d="M12,3V13.55C11.41,13.21 10.73,13 10,13A3,3 0 0,0 7,16A3,3 0 0,0 10,19A3,3 0 0,0 13,16V7H19V5H12Z"/>
                        </svg>
                    </div>
                    <div class="empty-state-title">No songs uploaded yet</div>
            `;
            songCount.textContent = '0 songs';
            return;
        }

        songList.innerHTML = this.songs.map((song, index) => `
            <li class="song-item" data-index="${index}">
                <div class="song-number">${String(index + 1).padStart(2, '0')}</div>
                <div class="song-title">${this.formatSongTitle(song)}</div>
                <div class="song-actions">
                    <button class="favorite-btn ${this.favorites.has(song) ? 'favorited' : ''}" 
                            data-song="${song}" title="Add to favorites">
                        <svg width="16" height="16" viewBox="0 0 24 24" fill="${this.favorites.has(song) ? 'var(--accent-color)' : 'none'}" stroke="currentColor" stroke-width="2">
                            <path d="M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z"/>
                        </svg>
                    </button>
                    <button class="add-to-playlist-btn" 
                            data-song="${song}" title="Add to playlist">
                        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                            <path d="M19 13H13v6h-2v-6H5v-2h6V5h2v6h6v2z"/>
                        </svg>
                    </button>
                    <div class="song-format">FLAC</div>
                </div>
            </li>
        `).join('');

        songCount.textContent = `${this.songs.length} songs`;
        
        // Add favorite button listeners
        document.querySelectorAll('.favorite-btn').forEach(btn => {
            btn.addEventListener('click', (e) => {
                e.stopPropagation();
                this.toggleFavorite(btn.dataset.song);
            });
        });
    }

    toggleFavorite(song) {
        if (this.favorites.has(song)) {
            this.favorites.delete(song);
        } else {
            this.favorites.add(song);
        }
        
        // Save to localStorage
        localStorage.setItem('favorites', JSON.stringify([...this.favorites]));
        
        // Update UI if in favorites section
        if (this.currentSection === 'favorites') {
            this.loadFavorites();
        }
        
        // Update favorite buttons in current list
        this.renderSongList();
    }

    async loadCacheStats() {
        try {
            const response = await fetch('/api/cache-stats');
            const stats = await response.json();
            
            const cacheStatsDiv = document.getElementById('cache-stats');
            cacheStatsDiv.innerHTML = `
                <div class="cache-stat-item">
                    <span class="cache-stat-label">Cached Files</span>
                    <span class="cache-stat-value">${stats.cached_files}</span>
                </div>
                <div class="cache-stat-item">
                    <span class="cache-stat-label">Cache Hits</span>
                    <span class="cache-stat-value">${stats.cache_hits}</span>
                </div>
                <div class="cache-stat-item">
                    <span class="cache-stat-label">Cache Misses</span>
                    <span class="cache-stat-value">${stats.cache_misses}</span>
                </div>
                <div class="cache-stat-item">
                    <span class="cache-stat-label">Hit Rate</span>
                    <span class="cache-stat-value">${stats.hit_rate.toFixed(1)}%</span>
                </div>
                <div class="cache-stat-item">
                    <span class="cache-stat-label">Status</span>
                    <span class="cache-stat-value">${stats.message}</span>
                </div>
            `;
        } catch (error) {
            console.error('Failed to load cache stats:', error);
            document.getElementById('cache-stats').innerHTML = `
                <div class="empty-state">
                    <div class="empty-state-icon">
                        <svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor">
                            <path d="M12,2A10,10 0 0,0 2,12A10,10 0 0,0 12,22A10,10 0 0,0 22,12A10,10 0 0,0 12,2M12,4A8,8 0 0,1 20,12A8,8 0 0,1 12,20A8,8 0 0,1 4,12A8,8 0 0,1 12,4M12,6A6,6 0 0,0 6,12A6,6 0 0,0 12,18A6,6 0 0,0 18,12A6,6 0 0,0 12,6M13,9H11V11H13M13,13H11V17H13"/>
                        </svg>
                    </div>
                    <div class="empty-state-title">Failed to load cache stats</div>
                </div>
            `;
        }
    }

    async clearCache() {
        try {
            const response = await fetch('/api/clear-cache');
            const result = await response.json();
            
            this.showNotification('Cache cleared successfully', 'success');
            
            // Reload cache stats
            if (this.currentSection === 'cache') {
                this.loadCacheStats();
            }
        } catch (error) {
            console.error('Failed to clear cache:', error);
            this.showNotification('❌ Failed to clear cache', 'error');
        }
    }

    loadTF2Playlist() {
        const tf2Songs = this.songs.filter(song => 
            song.toLowerCase().includes('valve') || 
            song.toLowerCase().includes('team fortress') ||
            song.toLowerCase().includes('tf2')
        );
        
        const tf2List = document.getElementById('tf2-list');
        const tf2Count = document.getElementById('tf2-count');
        
        if (tf2Songs.length === 0) {
            tf2List.innerHTML = `
                <div class="empty-state">
                    <div class="empty-state-icon">🎮</div>
                    <div class="empty-state-title">No Team Fortress 2 music found</div>
                    <div class="empty-state-description">
                        Songs from Valve Studio Orchestra will appear here.
                    </div>
                </div>
            `;
        } else {
            tf2List.innerHTML = tf2Songs.map((song, index) => {
                const originalIndex = this.songs.indexOf(song);
                return `
                    <li class="song-item" data-index="${originalIndex}">
                        <div class="song-number">${String(index + 1).padStart(2, '0')}</div>
                        <div class="song-title">${this.formatSongTitle(song)}</div>
                        <div class="song-actions">
                            <button class="favorite-btn ${this.favorites.has(song) ? 'favorited' : ''}" 
                                    data-song="${song}" title="Add to favorites">
                                <svg width="16" height="16" viewBox="0 0 24 24" fill="${this.favorites.has(song) ? 'var(--accent-color)' : 'none'}" stroke="currentColor" stroke-width="2">
                                    <path d="M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z"/>
                                </svg>
                            </button>
                            <button class="add-to-playlist-btn" 
                                    data-song="${song}" title="Add to playlist">
                                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                                    <path d="M19 13H13v6h-2v-6H5v-2h6V5h2v6h6v2z"/>
                                </svg>
                            </button>
                            <div class="song-format">FLAC</div>
                        </div>
                    </li>
                `;
            }).join('');
            
            // Add click listeners for TF2 playlist
            tf2List.addEventListener('click', (e) => {
                const songItem = e.target.closest('.song-item');
                if (songItem) {
                    if (e.target.closest('.add-to-playlist-btn')) {
                        const song = e.target.closest('.add-to-playlist-btn').dataset.song;
                        this.showAddToPlaylistDialog(song);
                    } else if (!e.target.classList.contains('favorite-btn')) {
                        const index = parseInt(songItem.dataset.index);
                        this.playSong(index);
                    }
                }
            });
            
            // Add favorite button listeners
            tf2List.querySelectorAll('.favorite-btn').forEach(btn => {
                btn.addEventListener('click', (e) => {
                    e.stopPropagation();
                    this.toggleFavorite(btn.dataset.song);
                });
            });
        }
        
        tf2Count.textContent = `${tf2Songs.length} songs`;
    }

    loadFavorites() {
        const favoriteSongs = this.songs.filter(song => this.favorites.has(song));
        
        const favoritesList = document.getElementById('favorites-list');
        const favoritesCount = document.getElementById('favorites-count');
        
        if (favoriteSongs.length === 0) {
            favoritesList.innerHTML = `
                <div class="empty-state">
                    <div class="empty-state-icon">
                        <svg width="48" height="48" viewBox="0 0 24 24" fill="currentColor">
                            <path d="M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z"/>
                        </svg>
                    </div>
                    <div class="empty-state-title">No favorites yet</div>
                    <div class="empty-state-description">
                        Click the heart icon next to songs to add them to your favorites.
                    </div>
                </div>
            `;
        } else {
            favoritesList.innerHTML = favoriteSongs.map((song, index) => {
                const originalIndex = this.songs.indexOf(song);
                return `
                    <li class="song-item" data-index="${originalIndex}">
                        <div class="song-number">${String(index + 1).padStart(2, '0')}</div>
                        <div class="song-title">${this.formatSongTitle(song)}</div>
                        <div class="song-actions">
                            <button class="favorite-btn favorited" 
                                    data-song="${song}" title="Remove from favorites">
                                <svg width="16" height="16" viewBox="0 0 24 24" fill="var(--accent-color)" stroke="var(--accent-color)" stroke-width="1">
                                    <path d="M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z"/>
                                </svg>
                            </button>
                            <button class="add-to-playlist-btn" 
                                    data-song="${song}" title="Add to playlist">
                                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                                    <path d="M19 13H13v6h-2v-6H5v-2h6V5h2v6h6v2z"/>
                                </svg>
                            </button>
                            <div class="song-format">FLAC</div>
                        </div>
                    </li>
                `;
            }).join('');
            
            // Add click listeners for favorites
            favoritesList.addEventListener('click', (e) => {
                const songItem = e.target.closest('.song-item');
                if (songItem) {
                    if (e.target.closest('.add-to-playlist-btn')) {
                        const song = e.target.closest('.add-to-playlist-btn').dataset.song;
                        this.showAddToPlaylistDialog(song);
                    } else if (!e.target.classList.contains('favorite-btn')) {
                        const index = parseInt(songItem.dataset.index);
                        this.playSong(index);
                    }
                }
            });
            
            // Add favorite button listeners
            favoritesList.querySelectorAll('.favorite-btn').forEach(btn => {
                btn.addEventListener('click', (e) => {
                    e.stopPropagation();
                    this.toggleFavorite(btn.dataset.song);
                });
            });
        }
        
        favoritesCount.textContent = `${favoriteSongs.length} songs`;
    }

    showNotification(message, type = 'info') {
        // Create a simple toast notification
        const toast = document.createElement('div');
        toast.className = `notification-toast ${type}`;
        toast.textContent = message;
        toast.style.cssText = `
            position: fixed;
            top: 20px;
            right: 20px;
            background: ${type === 'success' ? '#4CAF50' : type === 'error' ? '#f44336' : '#2196F3'};
            color: white;
            padding: 12px 16px;
            border-radius: 8px;
            box-shadow: 0 4px 12px rgba(0, 0, 0, 0.3);
            z-index: 1000;
            opacity: 0;
            transform: translateX(100%);
            transition: all 0.3s ease;
        `;
        
        document.body.appendChild(toast);
        
        // Animate in
        setTimeout(() => {
            toast.style.opacity = '1';
            toast.style.transform = 'translateX(0)';
        }, 100);
        
        // Remove after 3 seconds
        setTimeout(() => {
            toast.style.opacity = '0';
            toast.style.transform = 'translateX(100%)';
            setTimeout(() => {
                if (toast.parentNode) {
                    toast.parentNode.removeChild(toast);
                }
            }, 300);
        }, 3000);
    }

    formatSongTitle(filename) {
        // Remove file extension and clean up the title
        return filename
            .replace(/\.(flac|mp3|wav|m4a)$/i, '')
            .replace(/^\d+\s*-\s*/, '') // Remove track numbers
            .trim();
    }

    async playSong(index) {
        if (index < 0 || index >= this.songs.length) return;

        this.currentIndex = index;
        this.currentSong = this.songs[index];
        
        try {
            this.showLoadingState();
            
            // Update UI immediately
            this.updateNowPlaying(index);
            this.updateActiveSong(index);
            
            // Load and play the audio
            this.audioPlayer.src = `/music/${encodeURIComponent(this.currentSong)}`;
            await this.audioPlayer.load();
            
            // Always play when a song is selected
            await this.audioPlayer.play();
            
            this.hideLoadingState();
        } catch (error) {
            console.error('Failed to play song:', error);
            this.showError(`Failed to play: ${this.currentSong}`);
            this.hideLoadingState();
        }
    }

    togglePlayPause() {
        if (!this.currentSong) {
            if (this.songs.length > 0) {
                this.playSong(0);
            }
            return;
        }

        if (this.isPlaying) {
            this.audioPlayer.pause();
        } else {
            this.audioPlayer.play().catch(error => {
                console.error('Failed to play:', error);
                this.showError('Failed to play audio');
            });
        }
    }

    previousSong() {
        let newIndex;
        if (this.isShuffling) {
            // In shuffle mode, pick a random song that's not the current one
            do {
                newIndex = Math.floor(Math.random() * this.songs.length);
            } while (newIndex === this.currentIndex && this.songs.length > 1);
        } else {
            newIndex = this.currentIndex > 0 ? this.currentIndex - 1 : this.songs.length - 1;
        }
        this.playSong(newIndex);
    }

    nextSong() {
        let newIndex;
        if (this.isShuffling) {
            // In shuffle mode, pick a random song that's not the current one
            do {
                newIndex = Math.floor(Math.random() * this.songs.length);
            } while (newIndex === this.currentIndex && this.songs.length > 1);
        } else {
            newIndex = this.currentIndex < this.songs.length - 1 ? this.currentIndex + 1 : 0;
        }
        this.playSong(newIndex);
    }

    toggleShuffle() {
        this.isShuffling = !this.isShuffling;
        const shuffleBtn = document.getElementById('shuffle-btn');
        shuffleBtn.classList.toggle('active', this.isShuffling);
        shuffleBtn.title = this.isShuffling ? 'Shuffle: ON' : 'Shuffle';
    }

    toggleRepeat() {
        // Cycle through repeat modes: off -> all -> one -> off
        if (!this.repeatMode || this.repeatMode === 'off') {
            this.repeatMode = 'all';
        } else if (this.repeatMode === 'all') {
            this.repeatMode = 'one';
        } else {
            this.repeatMode = 'off';
        }
        
        const repeatBtn = document.getElementById('repeat-btn');
        const repeatIcon = repeatBtn.querySelector('.repeat-icon');
        
        // Update button appearance and functionality
        repeatBtn.setAttribute('data-repeat', this.repeatMode);
        
        switch (this.repeatMode) {
            case 'off':
                repeatBtn.title = 'Repeat: Off';
                repeatIcon.innerHTML = '<path d="M7 7h10v3l4-4-4-4v3H5v6h2V7zm10 10H7v-3l-4 4 4 4v-3h12v-6h-2v4z"/>';
                break;
            case 'all':
                repeatBtn.title = 'Repeat: All Songs';
                repeatIcon.innerHTML = '<path d="M7 7h10v3l4-4-4-4v3H5v6h2V7zm10 10H7v-3l-4 4 4 4v-3h12v-6h-2v4z"/>';
                break;
            case 'one':
                repeatBtn.title = 'Repeat: Current Song';
                repeatIcon.innerHTML = '<path d="M7 7h10v3l4-4-4-4v3H5v6h2V7zm10 10H7v-3l-4 4 4 4v-3h12v-6h-2v4z"/>';
                break;
        }
        
        console.log(`🔁 Repeat mode: ${this.repeatMode}`);
    }

    updatePlayPauseButton() {
        const playPauseIcon = document.getElementById('play-pause-icon');
        const playPauseBtn = document.getElementById('play-pause-btn');
        
        if (this.isPlaying) {
            playPauseIcon.innerHTML = '<path d="M6 19h4V5H6v14zm8-14v14h4V5h-4z"/>';
            playPauseBtn.title = 'Pause';
        } else {
            playPauseIcon.innerHTML = '<path d="M8 5v14l11-7z"/>';
            playPauseBtn.title = 'Play';
        }
    }

    updateNowPlaying(index) {
        if (index < 0 || index >= this.songs.length) return;

        const song = this.songs[index];
        const trackTitle = document.getElementById('track-title');
        const trackArtist = document.getElementById('track-artist');
        
        trackTitle.textContent = this.formatSongTitle(song);
        trackArtist.textContent = this.extractArtist(song);
    }

    extractArtist(song) {
        // Extract artist from filename patterns like "Artist - Title" or "22. Artist - Title"
        const cleanName = this.formatSongTitle(song);
        
        // Check if it contains " - " separator
        if (cleanName.includes(' - ')) {
            const parts = cleanName.split(' - ');
            if (parts.length >= 2) {
                // Return the first part as artist, but clean it up
                let artist = parts[0].trim();
                
                // Remove track numbers like "01.", "22.", etc.
                artist = artist.replace(/^\d+\.\s*/, '');
                
                return artist || 'Unknown Artist';
            }
        }
        
        // Fallback: try to detect known artists in filename
        const knownArtists = ['Valve Studio Orchestra', 'd4vd', 'Team Fortress'];
        for (const knownArtist of knownArtists) {
            if (cleanName.toLowerCase().includes(knownArtist.toLowerCase())) {
                return knownArtist;
            }
        }
        
        return 'Unknown Artist';
    }

    updateActiveSong(index) {
        // Remove active class from all songs
        document.querySelectorAll('.song-item').forEach(item => {
            item.classList.remove('active');
        });
        
        // Add active class to current song
        const currentSongItem = document.querySelector(`[data-index="${index}"]`);
        if (currentSongItem) {
            currentSongItem.classList.add('active');
            currentSongItem.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
        }
    }

    showLoadingState() {
        const nowPlayingCard = document.querySelector('.now-playing-card');
        const existingLoader = nowPlayingCard.querySelector('.loading-indicator');
        
        if (!existingLoader) {
            const loader = document.createElement('div');
            loader.className = 'loading-indicator';
            loader.innerHTML = `
                <div class="loading-icon">
                    <svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor">
                        <path d="M12,3V13.55C11.41,13.21 10.73,13 10,13A3,3 0 0,0 7,16A3,3 0 0,0 10,19A3,3 0 0,0 13,16V7H19V5H12Z"/>
                    </svg>
                </div>
                <div class="loading-text">Loading...</div>
            `;
            loader.style.cssText = `
                position: absolute;
                top: 50%;
                left: 50%;
                transform: translate(-50%, -50%);
                text-align: center;
                color: var(--text-secondary);
                z-index: 10;
            `;
            
            nowPlayingCard.style.position = 'relative';
            nowPlayingCard.appendChild(loader);
        }
    }

    hideLoadingState() {
        const loader = document.querySelector('.loading-indicator');
        if (loader) {
            loader.remove();
        }
    }

    showError(message) {
        // Create a simple toast notification
        const toast = document.createElement('div');
        toast.className = 'error-toast';
        toast.textContent = message;
        toast.style.cssText = `
            position: fixed;
            top: 20px;
            right: 20px;
            background: #ff4444;
            color: white;
            padding: 12px 16px;
            border-radius: 8px;
            box-shadow: 0 4px 12px rgba(0, 0, 0, 0.3);
            z-index: 1000;
            opacity: 0;
            transform: translateX(100%);
            transition: all 0.3s ease;
        `;
        
        document.body.appendChild(toast);
        
        // Animate in
        setTimeout(() => {
            toast.style.opacity = '1';
            toast.style.transform = 'translateX(0)';
        }, 100);
        
        // Remove after 5 seconds
        setTimeout(() => {
            toast.style.opacity = '0';
            toast.style.transform = 'translateX(100%)';
            setTimeout(() => {
                if (toast.parentNode) {
                    toast.parentNode.removeChild(toast);
                }
            }, 300);
        }, 5000);
    }
}

// Cache management functionality
async function loadCacheStats() {
    if (window.musicPlayer) {
        await window.musicPlayer.loadCacheStats();
    }
}

// Initialize the application
document.addEventListener('DOMContentLoaded', () => {
    const musicPlayer = new MusicPlayer();
    window.musicPlayer = musicPlayer;
    
    // Load cache stats periodically
    setInterval(() => {
        if (musicPlayer.currentSection === 'cache') {
            musicPlayer.loadCacheStats();
        }
    }, 30000);
});

// Keyboard shortcuts
document.addEventListener('keydown', (e) => {
    if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA') return;
    
    switch (e.code) {
        case 'Space':
            e.preventDefault();
            window.musicPlayer?.togglePlayPause();
            break;
        case 'ArrowLeft':
            e.preventDefault();
            window.musicPlayer?.previousSong();
            break;
        case 'ArrowRight':
            e.preventDefault();
            window.musicPlayer?.nextSong();
            break;
    }
});
