Synthetic fixture: six seconds of blue video and a 440 Hz tone, generated locally.
Contains no third-party film, account information, subscription or network URL.

Regenerate with FFmpeg:

```sh
ffmpeg -f lavfi -i color=c=blue:s=640x360:r=24 -f lavfi -i sine=frequency=440:sample_rate=48000 -t 6 -c:v libx265 -preset ultrafast -x265-params log-level=error:pools=1 -c:a aac -b:a 32k cloud-playback.mkv
```
