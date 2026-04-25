#!/usr/bin/env python3
"""
Procedural music generator for Tower Defense PVP/PVE.
Medieval fantasy themed - D minor key, additive synthesis.

Usage: python3 tools/gen_music.py
Writes to assets/audio/music_menu.ogg, music_prep.ogg, music_battle.ogg
"""

import wave, struct, math, random, os, subprocess, tempfile

SR  = 22050
TAU = 2.0 * math.pi

# ---------------------------------------------------------------------------
# Note frequencies - D natural minor + pentatonic
# ---------------------------------------------------------------------------
NOTES = {
    'A1': 55.00,  'C2': 65.41,  'D2': 73.42,  'F2': 87.31,  'G2': 98.00,
    'A2': 110.00, 'Bb2': 116.54, 'C3': 130.81, 'D3': 146.83, 'E3': 164.81,
    'F3': 174.61, 'G3': 196.00, 'A3': 220.00, 'Bb3': 233.08, 'C4': 261.63,
    'D4': 293.66, 'E4': 329.63, 'F4': 349.23, 'G4': 392.00, 'A4': 440.00,
    'Bb4': 466.16, 'C5': 523.25, 'D5': 587.33, 'E5': 659.25, 'F5': 698.46,
    'G5': 784.00,
}

# ---------------------------------------------------------------------------
# Envelope helper
# ---------------------------------------------------------------------------

def _env(i, n, attack, decay, sustain, release):
    t = i / SR
    dur = n / SR
    if t < attack:
        return t / attack if attack > 0 else 1.0
    t -= attack
    if t < decay:
        return 1.0 - (1.0 - sustain) * (t / decay) if decay > 0 else sustain
    t -= decay
    s_dur = dur - attack - decay - release
    if s_dur < 0:
        s_dur = 0
    if t < s_dur:
        return sustain
    t -= s_dur
    if t < release:
        return sustain * (1.0 - t / release) if release > 0 else 0.0
    return 0.0

# ---------------------------------------------------------------------------
# Synth voices
# ---------------------------------------------------------------------------

def synth_pad(freq, dur, attack=0.3, decay=0.4, sustain=0.7, release=0.5,
              lfo_rate=0.35, lfo_depth=0.035):
    """String-like sustained pad - detuned trio with slow LFO."""
    n = int(SR * dur)
    f1, f2, f3 = freq, freq * 1.004, freq * 0.996
    lfo_k = TAU * lfo_rate / SR
    return [
        (math.sin(TAU * f1 * i / SR) * 0.50
         + math.sin(TAU * f2 * i / SR) * 0.30
         + math.sin(TAU * f3 * i / SR) * 0.20)
        * _env(i, n, attack, decay, sustain, release)
        * (1.0 + lfo_depth * math.sin(lfo_k * i))
        for i in range(n)
    ]

def synth_organ(freq, dur, attack=0.008, decay=0.06, sustain=0.5, release=0.12):
    """Harp-like plucked voice - 4 harmonics, short envelope."""
    n = int(SR * dur)
    k = TAU * freq / SR
    return [
        (math.sin(k * i) * 0.55
         + math.sin(k * 2 * i) * 0.25
         + math.sin(k * 3 * i) * 0.12
         + math.sin(k * 4 * i) * 0.08)
        * _env(i, n, attack, decay, sustain, release)
        for i in range(n)
    ]

def synth_bass(freq, dur, attack=0.005, decay=0.08, sustain=0.65, release=0.1):
    """Deep bass with sub-octave."""
    n = int(SR * dur)
    k = TAU * freq / SR
    return [
        (math.sin(k * i) * 0.60
         + math.sin(k * 0.5 * i) * 0.25
         + math.sin(k * 2.0 * i) * 0.15)
        * _env(i, n, attack, decay, sustain, release)
        for i in range(n)
    ]

def synth_lead(freq, dur, attack=0.015, decay=0.06, sustain=0.65, release=0.15,
               vibrato=0.004):
    """Flute-like lead with vibrato."""
    n = int(SR * dur)
    vib_k = TAU * 6.0 / SR
    k_base = TAU * freq / SR
    samples = []
    phase = 0.0
    for i in range(n):
        vib = 1.0 + vibrato * math.sin(vib_k * i)
        phase += k_base * vib
        env = _env(i, n, attack, decay, sustain, release)
        s = (math.sin(phase) * 0.50
             + math.sin(phase * 2) * 0.28
             + math.sin(phase * 3) * 0.14
             + math.sin(phase * 0.5) * 0.08)
        samples.append(s * env)
    return samples

def synth_bell(freq, dur, attack=0.002, decay=0.15, sustain=0.3, release=0.6):
    """Bell/chime - strong fundamental with inharmonic partials, long ring."""
    n = int(SR * dur)
    k = TAU * freq / SR
    return [
        (math.sin(k * i) * 0.50
         + math.sin(k * 2.0 * i) * 0.22
         + math.sin(k * 3.03 * i) * 0.15
         + math.sin(k * 4.07 * i) * 0.08
         + math.sin(k * 5.2 * i) * 0.05)
        * _env(i, n, attack, decay, sustain, release)
        for i in range(n)
    ]

def synth_kick():
    """War drum - low boomy kick."""
    dur = 0.34
    n = int(SR * dur)
    out = []
    prev = 0.0
    for i in range(n):
        t = i / SR
        env  = math.exp(-10.0 * t)
        tenv = math.exp(-50.0 * t)
        freq = 60.0 * math.exp(-15.0 * t)
        raw = math.sin(TAU * freq * t) * 0.85 + random.uniform(-1, 1) * 0.18 * tenv
        s = raw * env
        y = prev + 0.35 * (s - prev)
        out.append(y)
        prev = y
    return out

def synth_snare():
    """Marching snare - more noise, tight."""
    dur = 0.16
    n = int(SR * dur)
    return [
        (random.uniform(-1, 1) * 0.75
         + math.sin(TAU * 200.0 * i / SR) * 0.25 * math.exp(-40.0 * i / SR))
        * math.exp(-24.0 * i / SR)
        for i in range(n)
    ]

def synth_hihat(vol=0.16, dur=0.04):
    """Light cymbal tap."""
    n = int(SR * dur)
    out = []
    prev = 0.0
    for i in range(n):
        raw = random.uniform(-1, 1) * math.exp(-55.0 * i / SR) * vol
        y = prev + 0.6 * (raw - prev)
        out.append(y)
        prev = y
    return out

# ---------------------------------------------------------------------------
# Buffer helpers
# ---------------------------------------------------------------------------

def make_buf(dur_sec):
    return [0.0] * int(SR * dur_sec)

def mix_at(buf, samples, start_sec, vol=1.0):
    start = int(start_sec * SR)
    end   = min(start + len(samples), len(buf))
    n     = end - start
    for i in range(n):
        buf[start + i] += samples[i] * vol

def normalize_buf(buf, peak=0.82):
    mx = max(abs(s) for s in buf)
    if mx > 1e-9:
        k = peak / mx
        for i in range(len(buf)):
            buf[i] *= k
    return buf

def fade_edges(buf, fade_sec=0.07):
    n = int(fade_sec * SR)
    for i in range(n):
        t = i / n
        buf[i] *= t
        buf[-(i + 1)] *= t
    return buf

# ---------------------------------------------------------------------------
# WAV / OGG I/O
# ---------------------------------------------------------------------------

def save_wav(path, buf):
    with wave.open(path, 'w') as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(SR)
        data = struct.pack(f'<{len(buf)}h',
                           *[int(max(-32767, min(32767, s * 32767))) for s in buf])
        wf.writeframes(data)

def to_ogg(wav_path, ogg_path):
    subprocess.run(
        ['ffmpeg', '-y', '-i', wav_path, '-ar', '44100', '-ac', '2',
         '-strict', 'experimental', '-c:a', 'vorbis', ogg_path],
        check=True, capture_output=True
    )

def gen(name, buf, out_dir):
    with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as f:
        tmp = f.name
    save_wav(tmp, buf)
    ogg = os.path.join(out_dir, name + '.ogg')
    to_ogg(tmp, ogg)
    os.unlink(tmp)
    print(f'  wrote {ogg}')

# ---------------------------------------------------------------------------
# MENU MUSIC - "The Kingdom"
# Stately and mysterious. 3/4 waltz time, 68 BPM, 24 bars (~63 s).
# Starts with solo bell chimes, layers build gradually.
# Structure: A(8) -> B(8) -> A'(8) with additive layering.
# ---------------------------------------------------------------------------

def make_menu_music():
    BPM    = 68
    beat   = 60.0 / BPM
    bar    = beat * 3          # 3/4 time
    n_bars = 24
    total_dur = bar * n_bars
    buf = make_buf(total_dur)

    # --- Section A (bars 0-7): Bell chimes + drone ---
    # Sparse bell melody in 3/4, like a music box
    bell_melody_a = [
        # (bar, beat_offset, note, dur_beats)
        (0, 0, 'D5', 1.5), (0, 2, 'A4', 0.8),
        (1, 0, 'F4', 2.0), (1, 2.5, 'G4', 0.5),
        (2, 0, 'A4', 1.0), (2, 1, 'G4', 0.5), (2, 2, 'F4', 1.0),
        (3, 0, 'D4', 3.0),
        (4, 0, 'D5', 1.0), (4, 1.5, 'C5', 0.5), (4, 2, 'A4', 1.0),
        (5, 0, 'Bb4', 2.5),
        (6, 0, 'A4', 1.0), (6, 1, 'F4', 1.0), (6, 2, 'G4', 1.0),
        (7, 0, 'D4', 3.0),
    ]
    for b_off, beat_off, note, dur_b in bell_melody_a:
        t0 = b_off * bar + beat_off * beat
        mix_at(buf, synth_bell(NOTES[note], dur_b * beat * 1.8,
                               attack=0.002, decay=0.25, sustain=0.2, release=1.2),
               t0, vol=0.28)

    # Low D drone fades in over first 4 bars
    drone_dur = 8 * bar
    drone = synth_pad(NOTES['D2'], drone_dur,
                      attack=3.0, decay=1.0, sustain=0.6, release=2.0,
                      lfo_rate=0.2, lfo_depth=0.03)
    mix_at(buf, drone, 0, vol=0.35)

    # --- Section B (bars 8-15): Add harp arpeggios + strings ---
    # Broken chord arpeggios in 3/4 - one note per beat
    arp_patterns = [
        ['D3','A3','F3'],   # Dm (2 bars)
        ['D3','A3','F3'],
        ['Bb2','F3','D3'],  # Bb (2 bars)
        ['Bb2','F3','D3'],
        ['C3','G3','E3'],   # C (2 bars)
        ['C3','G3','E3'],
        ['A2','E3','C3'],   # Am (2 bars)
        ['A2','E3','C3'],
    ]
    for bi in range(8):
        pat = arp_patterns[bi]
        for beat_idx in range(3):
            t0 = (8 + bi) * bar + beat_idx * beat
            note = pat[beat_idx % len(pat)]
            mix_at(buf, synth_organ(NOTES[note], beat * 0.7,
                                    attack=0.004, decay=0.05, sustain=0.35, release=0.15),
                   t0, vol=0.26)

    # String pads in section B (longer chords, 2 bars each)
    b_chords = [
        (['D3','F3','A3'], 2),      # Dm
        (['Bb2','D3','F3'], 2),     # Bb
        (['C3','E3','G3'], 2),      # C
        (['A2','C3','E3'], 2),      # Am
    ]
    cursor_bar = 8
    for chord, bars in b_chords:
        cdur = bar * bars * 0.88
        for note in chord:
            mix_at(buf, synth_pad(NOTES[note], cdur,
                                  attack=0.6, decay=0.5, sustain=0.68, release=0.9),
                   cursor_bar * bar, vol=0.20)
        cursor_bar += bars

    # Flute counter-melody in B section - longer lyrical phrases
    flute_b = [
        (8, 0, 'A4', 2.0), (8, 2, 'G4', 1.0),
        (9, 0, 'F4', 1.5), (9, 1.5, 'D4', 1.5),
        (10, 1, 'D4', 1.0), (10, 2, 'F4', 1.0),
        (11, 0, 'G4', 2.0), (11, 2, 'A4', 1.0),
        (12, 0, 'C5', 2.5),
        (13, 0, 'Bb4', 1.0), (13, 1, 'A4', 1.0), (13, 2, 'G4', 1.0),
        (14, 0, 'F4', 1.5), (14, 2, 'E4', 1.0),
        (15, 0, 'D4', 3.0),
    ]
    for b_off, beat_off, note, dur_b in flute_b:
        t0 = b_off * bar + beat_off * beat
        mix_at(buf, synth_lead(NOTES[note], dur_b * beat * 0.9,
                               attack=0.04, decay=0.15, sustain=0.55, release=0.4,
                               vibrato=0.006),
               t0, vol=0.24)

    # --- Section A' (bars 16-23): Everything together, bell returns ---
    # Drone continues
    drone2 = synth_pad(NOTES['D2'], 8 * bar,
                       attack=0.5, decay=0.5, sustain=0.6, release=2.5,
                       lfo_rate=0.2, lfo_depth=0.03)
    mix_at(buf, drone2, 16 * bar, vol=0.32)

    # Bell melody returns transposed/varied
    bell_melody_a2 = [
        (16, 0, 'A4', 1.5), (16, 2, 'D5', 0.8),
        (17, 0, 'C5', 1.5), (17, 2, 'Bb4', 1.0),
        (18, 0, 'A4', 1.0), (18, 1.5, 'G4', 0.5), (18, 2, 'F4', 1.0),
        (19, 0, 'D4', 2.0), (19, 2, 'F4', 1.0),
        (20, 0, 'G4', 2.0), (20, 2, 'A4', 1.0),
        (21, 0, 'F4', 3.0),
        (22, 0, 'D4', 1.0), (22, 1, 'E4', 1.0), (22, 2, 'F4', 1.0),
        (23, 0, 'D4', 3.0),
    ]
    for b_off, beat_off, note, dur_b in bell_melody_a2:
        t0 = b_off * bar + beat_off * beat
        mix_at(buf, synth_bell(NOTES[note], dur_b * beat * 1.8,
                               attack=0.002, decay=0.25, sustain=0.2, release=1.2),
               t0, vol=0.25)

    # Harp continues in A' with varied pattern
    arp2_patterns = [
        ['D3','F3','A3'],
        ['D3','A3','D4'],
        ['G3','Bb3','D4'],
        ['G3','D3','Bb3'],
        ['C3','E3','G3'],
        ['C3','G3','C4'],
        ['D3','F3','A3'],
        ['D3','A3','D3'],
    ]
    for bi in range(8):
        pat = arp2_patterns[bi]
        for beat_idx in range(3):
            t0 = (16 + bi) * bar + beat_idx * beat
            note = pat[beat_idx % len(pat)]
            mix_at(buf, synth_organ(NOTES[note], beat * 0.65,
                                    attack=0.004, decay=0.05, sustain=0.35, release=0.15),
                   t0, vol=0.22)

    # Strings in A' resolving back to D minor
    a2_chords = [
        (['D3','F3','A3'], 2),
        (['G3','Bb3','D4'], 2),
        (['C3','E3','G3'], 2),
        (['D3','F3','A3'], 2),
    ]
    cursor_bar = 16
    for chord, bars in a2_chords:
        cdur = bar * bars * 0.88
        for note in chord:
            mix_at(buf, synth_pad(NOTES[note], cdur,
                                  attack=0.5, decay=0.4, sustain=0.65, release=1.0),
                   cursor_bar * bar, vol=0.18)
        cursor_bar += bars

    normalize_buf(buf)
    fade_edges(buf, fade_sec=0.12)
    return buf

# ---------------------------------------------------------------------------
# PREP MUSIC - "Fortify"
# Tense anticipation with a building ostinato. 100 BPM, 4/4, 20 bars (~48 s).
# Layers enter progressively: tick -> bass ostinato -> pads -> melody fragments.
# Uses a persistent 2-bar rhythmic cell that evolves.
# ---------------------------------------------------------------------------

def make_prep_music():
    BPM    = 100
    beat   = 60.0 / BPM
    bar    = beat * 4
    eighth = beat / 2.0
    n_bars = 20
    total_dur = bar * n_bars
    buf = make_buf(total_dur)

    # --- Ticking hihat ostinato (full duration, creates clock-like tension) ---
    # Syncopated pattern per bar: x.x..x.x x..x.x.. (16th grid)
    tick_pattern = [1,0,1,0,0,1,0,1, 1,0,0,1,0,1,0,0]  # 16 sixteenths = 1 bar
    sixteenth = beat / 4.0
    for b in range(n_bars):
        bt = b * bar
        for s16 in range(16):
            if tick_pattern[s16]:
                vol = 0.18 if (s16 in [0, 8]) else 0.12
                mix_at(buf, synth_hihat(vol=vol, dur=0.035), bt + s16 * sixteenth)

    # --- Bass ostinato enters bar 2, 2-bar repeating cell ---
    # Rhythmically varied: not straight 8ths. Uses dotted rhythms.
    # Pattern: D(dotted-quarter) _ D(8th) F(quarter) G(quarter) A(8th) G(8th)
    #          D(dotted-quarter) _ D(8th) C(quarter) D(half)
    ostinato_events = [
        # bar-offset, beat-offset, note, duration-in-beats
        (0, 0.0, 'D2', 1.5),
        (0, 1.5, 'D2', 0.5),
        (0, 2.0, 'F2', 1.0),
        (0, 3.0, 'G2', 0.5), (0, 3.5, 'A2', 0.5),
        (1, 0.0, 'D2', 1.5),
        (1, 1.5, 'D2', 0.5),
        (1, 2.0, 'C2', 1.0),
        (1, 3.0, 'D2', 1.0),
    ]
    for start_bar in range(2, n_bars, 2):
        vol_scale = min(1.0, 0.6 + (start_bar - 2) * 0.04)  # gradually louder
        for bar_off, beat_off, note, dur_b in ostinato_events:
            b = start_bar + bar_off
            if b >= n_bars:
                break
            t0 = b * bar + beat_off * beat
            mix_at(buf, synth_bass(NOTES[note], dur_b * beat * 0.85,
                                   attack=0.006, decay=0.08, sustain=0.62, release=0.1),
                   t0, vol=0.44 * vol_scale)

    # --- War drum enters bar 4 with a non-standard pattern ---
    # Beat 1: kick, beat 2.5: kick, beat 4: kick (asymmetric)
    kick_s = synth_kick()
    for b in range(4, n_bars):
        bt = b * bar
        mix_at(buf, kick_s, bt, vol=0.40)
        mix_at(buf, kick_s, bt + beat * 2.5, vol=0.30)
        # Add a third hit only in later bars for building intensity
        if b >= 10:
            mix_at(buf, kick_s, bt + beat * 3.5, vol=0.25)

    # --- String pads enter bar 6, 4-bar sustained chords ---
    prep_chords = [
        (['D3','A3','F3'], 4),      # Dm, bars 6-9
        (['G2','D3','Bb3'], 4),     # Gm, bars 10-13
        (['A2','E3','C4'], 2),      # Am, bars 14-15
        (['Bb2','F3','D4'], 2),     # Bb, bars 16-17
        (['A2','E3','C4'], 1),      # Am, bar 18
        (['D3','A3','F3'], 1),      # Dm, bar 19 (resolve)
    ]
    cursor_bar = 6
    for chord, bars in prep_chords:
        if cursor_bar >= n_bars:
            break
        actual_bars = min(bars, n_bars - cursor_bar)
        cdur = bar * actual_bars * 0.92
        for note in chord:
            mix_at(buf, synth_pad(NOTES[note], cdur,
                                  attack=0.7, decay=0.4, sustain=0.58, release=0.8),
                   cursor_bar * bar, vol=0.20)
        cursor_bar += bars

    # --- Melodic fragments enter bar 8, short 2-note "question" motifs ---
    # These get longer as the piece progresses (building tension)
    motifs = [
        # (start_bar, events: (beat_offset, note, dur_beats))
        (8,  [(0, 'D4', 1.0), (1.5, 'F4', 0.5)]),                          # 2 notes
        (10, [(0, 'A4', 1.0), (1.5, 'G4', 0.5), (2.5, 'F4', 1.0)]),       # 3 notes
        (12, [(0, 'D4', 0.75), (1, 'F4', 0.75), (2, 'G4', 0.75), (3, 'A4', 1.0)]),  # 4 notes
        (14, [(0, 'A4', 1.0), (1, 'Bb4', 0.5), (1.5, 'A4', 0.5),
              (2, 'G4', 1.0), (3, 'F4', 1.0)]),                             # 5 notes
        (16, [(0, 'D5', 1.5), (1.5, 'C5', 0.5), (2, 'A4', 1.0),
              (3, 'G4', 0.5), (3.5, 'F4', 0.5)]),
        (18, [(0, 'D4', 1.0), (1, 'F4', 0.5), (1.5, 'A4', 0.5),
              (2, 'G4', 1.0), (3, 'D4', 1.0)]),                             # resolve
    ]
    for start_bar, events in motifs:
        if start_bar >= n_bars:
            break
        for beat_off, note, dur_b in events:
            t0 = start_bar * bar + beat_off * beat
            mix_at(buf, synth_lead(NOTES[note], dur_b * beat * 0.88,
                                   attack=0.02, decay=0.08, sustain=0.58, release=0.22,
                                   vibrato=0.003),
                   t0, vol=0.26)

    # --- Bell accent on the "pivot" chord changes ---
    for b in [6, 10, 14, 18]:
        if b < n_bars:
            mix_at(buf, synth_bell(NOTES['D5'], beat * 2.0,
                                   attack=0.002, decay=0.18, sustain=0.15, release=0.8),
                   b * bar, vol=0.12)

    normalize_buf(buf)
    fade_edges(buf)
    return buf

# ---------------------------------------------------------------------------
# BATTLE MUSIC - "Storm the Gates"
# Driving and chaotic. 152 BPM, 4/4, 36 bars (~57 s).
# Uses a "drop" structure: Intro(4) -> Build(4) -> DROP(8) -> Breakdown(4)
#   -> Build2(4) -> DROP2(8) -> Outro(4).
# Drums vary per section. Bass has a riff, not straight 8ths.
# ---------------------------------------------------------------------------

def make_battle_music():
    BPM       = 152
    beat      = 60.0 / BPM
    bar       = beat * 4
    eighth    = beat / 2.0
    sixteenth = beat / 4.0
    n_bars    = 36
    total_dur = bar * n_bars
    buf = make_buf(total_dur)

    kick_s  = synth_kick()
    snare_s = synth_snare()

    # --- DRUMS (section-aware) ---
    for b in range(n_bars):
        bt = b * bar

        if b < 4:
            # Intro: kick only on 1, sparse hihats on quarters
            mix_at(buf, kick_s, bt, vol=0.50)
            for q in range(4):
                mix_at(buf, synth_hihat(vol=0.10), bt + q * beat)

        elif b < 8:
            # Build: kick 1+3, snare 2+4, 8th hihats
            mix_at(buf, kick_s,  bt, vol=0.55)
            mix_at(buf, snare_s, bt + beat, vol=0.40)
            mix_at(buf, kick_s,  bt + beat * 2, vol=0.50)
            mix_at(buf, snare_s, bt + beat * 3, vol=0.45)
            for s8 in range(8):
                mix_at(buf, synth_hihat(vol=0.10), bt + s8 * eighth)

        elif b < 16:
            # DROP 1: full intensity. Double-kick pattern + snare + 16th hats
            mix_at(buf, kick_s,  bt, vol=0.60)
            mix_at(buf, kick_s,  bt + beat * 0.75, vol=0.35)
            mix_at(buf, snare_s, bt + beat, vol=0.50)
            mix_at(buf, kick_s,  bt + beat * 2, vol=0.55)
            mix_at(buf, kick_s,  bt + beat * 2.75, vol=0.30)
            mix_at(buf, snare_s, bt + beat * 3, vol=0.50)
            for s16 in range(16):
                hv = 0.14 if (s16 % 4 == 0) else 0.08
                mix_at(buf, synth_hihat(vol=hv), bt + s16 * sixteenth)

        elif b < 20:
            # Breakdown: half-time feel, kick 1 only, snare on 3
            mix_at(buf, kick_s,  bt, vol=0.55)
            mix_at(buf, snare_s, bt + beat * 2, vol=0.50)
            for q in range(4):
                mix_at(buf, synth_hihat(vol=0.08), bt + q * beat)

        elif b < 24:
            # Build 2: same as build but add extra kick hit
            mix_at(buf, kick_s,  bt, vol=0.55)
            mix_at(buf, snare_s, bt + beat, vol=0.42)
            mix_at(buf, kick_s,  bt + beat * 1.5, vol=0.30)
            mix_at(buf, kick_s,  bt + beat * 2, vol=0.50)
            mix_at(buf, snare_s, bt + beat * 3, vol=0.48)
            mix_at(buf, kick_s,  bt + beat * 3.5, vol=0.28)
            for s8 in range(8):
                mix_at(buf, synth_hihat(vol=0.12), bt + s8 * eighth)

        elif b < 32:
            # DROP 2: same as drop 1 pattern
            mix_at(buf, kick_s,  bt, vol=0.60)
            mix_at(buf, kick_s,  bt + beat * 0.75, vol=0.35)
            mix_at(buf, snare_s, bt + beat, vol=0.50)
            mix_at(buf, kick_s,  bt + beat * 2, vol=0.55)
            mix_at(buf, kick_s,  bt + beat * 2.75, vol=0.30)
            mix_at(buf, snare_s, bt + beat * 3, vol=0.50)
            for s16 in range(16):
                hv = 0.14 if (s16 % 4 == 0) else 0.08
                mix_at(buf, synth_hihat(vol=hv), bt + s16 * sixteenth)

        else:
            # Outro: fade-down version of drop
            fade = 1.0 - (b - 32) * 0.2
            mix_at(buf, kick_s,  bt, vol=0.55 * fade)
            mix_at(buf, snare_s, bt + beat, vol=0.40 * fade)
            mix_at(buf, kick_s,  bt + beat * 2, vol=0.50 * fade)
            mix_at(buf, snare_s, bt + beat * 3, vol=0.40 * fade)
            for q in range(4):
                mix_at(buf, synth_hihat(vol=0.08 * fade), bt + q * beat)

    # --- BASS RIFF: 2-bar repeating riff with syncopation ---
    # Not straight 8ths -- rhythmic motif with rests
    riff_events = [
        # (bar_offset, beat_offset, note, dur_beats)
        (0, 0.0, 'D2', 0.75),
        (0, 1.0, 'D2', 0.5),
        (0, 1.75, 'F2', 0.75),
        (0, 2.5, 'G2', 0.5),
        (0, 3.0, 'A2', 0.5), (0, 3.5, 'G2', 0.5),
        (1, 0.0, 'F2', 0.75),
        (1, 1.0, 'D2', 0.5),
        (1, 1.75, 'C2', 0.75),
        (1, 2.5, 'D2', 1.5),
    ]
    # Riff plays in build + drop sections, silent in intro/breakdown
    riff_ranges = [(4, 16), (20, 36)]  # (start_bar, end_bar)
    for r_start, r_end in riff_ranges:
        for base_bar in range(r_start, min(r_end, n_bars), 2):
            vol_scale = 1.0
            if base_bar >= 32:
                vol_scale = 1.0 - (base_bar - 32) * 0.2
            for bar_off, beat_off, note, dur_b in riff_events:
                b = base_bar + bar_off
                if b >= n_bars:
                    break
                t0 = b * bar + beat_off * beat
                mix_at(buf, synth_bass(NOTES[note], dur_b * beat * 0.85,
                                       attack=0.005, decay=0.06, sustain=0.6, release=0.08),
                       t0, vol=0.52 * vol_scale)

    # Intro has a simple low D pulse
    for b in range(4):
        mix_at(buf, synth_bass(NOTES['D2'], bar * 0.9,
                               attack=0.15, decay=0.3, sustain=0.5, release=0.3),
               b * bar, vol=0.35)

    # --- ARPEGGIOS: only in drop sections, different patterns per drop ---
    # Drop 1 arpeggio: ascending D minor triad + octave
    arp1 = ['D4','F4','A4','D5','F5','D5','A4','F4']
    for b in range(8, 16):
        bt = b * bar
        for s in range(8):
            t0 = bt + s * eighth
            note = arp1[s % len(arp1)]
            mix_at(buf, synth_organ(NOTES[note], eighth * 0.65,
                                    attack=0.004, decay=0.04, sustain=0.38, release=0.06),
                   t0, vol=0.22)

    # Drop 2 arpeggio: different shape - wider intervals, 16ths
    arp2 = ['D4','A4','F4','D5','C5','G4','A4','F4',
            'D4','G4','Bb4','D5','A4','F4','G4','D4']
    for b in range(24, 32):
        bt = b * bar
        for s in range(16):
            t0 = bt + s * sixteenth
            note = arp2[s % len(arp2)]
            mix_at(buf, synth_organ(NOTES[note], sixteenth * 0.68,
                                    attack=0.003, decay=0.03, sustain=0.35, release=0.05),
                   t0, vol=0.20)

    # --- LEAD MELODY: different themes per section ---
    # Build (bars 4-7): short ascending "call to arms" motif
    build_melody = [
        (4, 0, 'D4', 1.0), (4, 1, 'F4', 1.0), (4, 2, 'A4', 2.0),
        (5, 2, 'G4', 1.0), (5, 3, 'A4', 1.0),
        (6, 0, 'D5', 2.0), (6, 2, 'C5', 1.0), (6, 3, 'A4', 1.0),
        (7, 0, 'G4', 2.0), (7, 2, 'F4', 1.0), (7, 3, 'D4', 1.0),
    ]
    for b_off, beat_off, note, dur_b in build_melody:
        t0 = b_off * bar + beat_off * beat
        mix_at(buf, synth_lead(NOTES[note], dur_b * beat * 0.9,
                               attack=0.01, decay=0.06, sustain=0.65, release=0.12,
                               vibrato=0.003),
               t0, vol=0.28)

    # Drop 1 (bars 8-15): heroic theme with longer held notes
    drop1_melody = [
        (8, 0, 'D5', 2.0), (8, 2, 'C5', 1.0), (8, 3, 'A4', 1.0),
        (9, 0, 'Bb4', 3.0), (9, 3, 'A4', 1.0),
        (10, 0, 'G4', 2.0), (10, 2, 'A4', 2.0),
        (11, 0, 'D5', 4.0),
        # second phrase
        (12, 0, 'F5', 1.5), (12, 1.5, 'D5', 0.5), (12, 2, 'C5', 1.0), (12, 3, 'A4', 1.0),
        (13, 0, 'Bb4', 2.0), (13, 2, 'A4', 1.0), (13, 3, 'G4', 1.0),
        (14, 0, 'F4', 2.0), (14, 2, 'G4', 1.0), (14, 3, 'A4', 1.0),
        (15, 0, 'D4', 4.0),
    ]
    for b_off, beat_off, note, dur_b in drop1_melody:
        t0 = b_off * bar + beat_off * beat
        mix_at(buf, synth_lead(NOTES[note], dur_b * beat * 0.88,
                               attack=0.01, decay=0.06, sustain=0.62, release=0.15,
                               vibrato=0.003),
               t0, vol=0.32)

    # Breakdown (bars 16-19): sparse, ominous, single low notes
    breakdown_melody = [
        (16, 0, 'D4', 3.0),
        (17, 1, 'C4', 2.0),
        (18, 0, 'A3', 2.0), (18, 2, 'Bb3', 2.0),
        (19, 0, 'A3', 4.0),
    ]
    for b_off, beat_off, note, dur_b in breakdown_melody:
        t0 = b_off * bar + beat_off * beat
        mix_at(buf, synth_lead(NOTES[note], dur_b * beat * 0.9,
                               attack=0.03, decay=0.1, sustain=0.5, release=0.3,
                               vibrato=0.006),
               t0, vol=0.22)

    # Build 2 (bars 20-23): variation of the build melody, higher energy
    build2_melody = [
        (20, 0, 'A4', 0.5), (20, 0.5, 'D5', 0.5), (20, 1, 'F5', 2.0),
        (20, 3, 'D5', 1.0),
        (21, 0, 'C5', 1.0), (21, 1, 'A4', 0.5), (21, 1.5, 'Bb4', 0.5),
        (21, 2, 'A4', 2.0),
        (22, 0, 'G4', 1.0), (22, 1, 'A4', 1.0), (22, 2, 'Bb4', 1.0),
        (22, 3, 'C5', 1.0),
        (23, 0, 'D5', 2.0), (23, 2, 'C5', 1.0), (23, 3, 'D5', 1.0),
    ]
    for b_off, beat_off, note, dur_b in build2_melody:
        t0 = b_off * bar + beat_off * beat
        mix_at(buf, synth_lead(NOTES[note], dur_b * beat * 0.88,
                               attack=0.01, decay=0.06, sustain=0.65, release=0.12,
                               vibrato=0.003),
               t0, vol=0.30)

    # Drop 2 (bars 24-31): climactic melody - the peak of the piece
    drop2_melody = [
        (24, 0, 'D5', 1.0), (24, 1, 'F5', 1.0), (24, 2, 'G5', 2.0),
        (25, 0, 'F5', 1.0), (25, 1, 'D5', 1.0), (25, 2, 'C5', 2.0),
        (26, 0, 'D5', 1.5), (26, 1.5, 'C5', 0.5), (26, 2, 'A4', 2.0),
        (27, 0, 'Bb4', 2.0), (27, 2, 'A4', 1.0), (27, 3, 'G4', 1.0),
        # second half - triumphant resolution
        (28, 0, 'D5', 2.0), (28, 2, 'A4', 1.0), (28, 3, 'Bb4', 1.0),
        (29, 0, 'C5', 1.5), (29, 1.5, 'D5', 0.5), (29, 2, 'F5', 2.0),
        (30, 0, 'G5', 2.0), (30, 2, 'F5', 1.0), (30, 3, 'D5', 1.0),
        (31, 0, 'D5', 4.0),
    ]
    for b_off, beat_off, note, dur_b in drop2_melody:
        t0 = b_off * bar + beat_off * beat
        mix_at(buf, synth_lead(NOTES[note], dur_b * beat * 0.88,
                               attack=0.01, decay=0.06, sustain=0.65, release=0.15,
                               vibrato=0.003),
               t0, vol=0.34)

    # --- CHORD STABS in drops only (not every 4 bars) ---
    drop_stabs = {
        8:  ['D3','F3','A3'],
        10: ['Bb2','D3','F3'],
        12: ['C3','E3','G3'],
        14: ['D3','F3','A3'],
        24: ['D3','F3','A3'],
        26: ['G3','Bb3','D4'],
        28: ['Bb2','D3','F3'],
        30: ['D3','F3','A3'],
    }
    for b, chord in drop_stabs.items():
        if b >= n_bars:
            continue
        for note in chord:
            mix_at(buf, synth_pad(NOTES[note], beat * 1.0,
                                  attack=0.005, decay=0.1, sustain=0.35, release=0.18),
                   b * bar, vol=0.20)

    normalize_buf(buf)
    fade_edges(buf)
    return buf

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if __name__ == '__main__':
    random.seed(42)

    script_dir = os.path.dirname(os.path.abspath(__file__))
    out_dir = os.path.join(script_dir, '..', 'assets', 'audio')
    os.makedirs(out_dir, exist_ok=True)

    tracks = [
        ('music_menu',   make_menu_music),
        ('music_prep',   make_prep_music),
        ('music_battle', make_battle_music),
    ]

    print(f'Generating {len(tracks)} music tracks -> {os.path.abspath(out_dir)}')
    for name, fn in tracks:
        print(f'  building {name}...')
        buf = fn()
        gen(name, buf, out_dir)
    print('Done.')
