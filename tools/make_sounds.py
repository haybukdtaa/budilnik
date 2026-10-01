"""Генерирует звуки будильника в Prosnis/Sounds. Все звуки синтезируются здесь,
поэтому нет проблем с авторскими правами. Запуск: python tools/make_sounds.py
"""
import os
import wave

import numpy as np

SR = 22050
DURATION = 24.0
OUT = os.path.join(os.path.dirname(__file__), "..", "Prosnis", "Sounds")
rng = np.random.default_rng(7)


def t_axis(seconds=DURATION):
    return np.arange(int(SR * seconds)) / SR


def normalize(x, peak=0.92):
    x = x - np.mean(x)
    return x / (np.max(np.abs(x)) + 1e-9) * peak


def save(name, x):
    x = normalize(x)
    # короткий вход и выход, чтобы не было щелчков на стыке цикла
    fade = int(SR * 0.01)
    x[:fade] *= np.linspace(0, 1, fade)
    x[-fade:] *= np.linspace(1, 0, fade)
    data = (x * 32767).astype("<i2").tobytes()
    os.makedirs(OUT, exist_ok=True)
    with wave.open(os.path.join(OUT, name + ".wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data)
    print("ok", name)


def tone(freq, t, harmonics=(1.0,)):
    return sum(a * np.sin(2 * np.pi * freq * (i + 1) * t) for i, a in enumerate(harmonics))


def gate(t, period, on):
    """Меандр: звук включён первые `on` секунд каждого периода."""
    return ((t % period) < on).astype(float)


def smooth(g, ms=8):
    n = max(1, int(SR * ms / 1000))
    return np.convolve(g, np.ones(n) / n, mode="same")


# --- Сигналы ---
t = t_axis()
beep = tone(1000, t, (1.0, 0.4, 0.2))
pattern = gate(t, 1.0, 0.12) + gate((t - 0.2) % 1.0, 1.0, 0.12) * (t > 0.2)
pattern += gate((t - 0.4) % 1.0, 1.0, 0.12) * (t > 0.4)
pattern += gate((t - 0.6) % 1.0, 1.0, 0.12) * (t > 0.6)
save("classic_beep", beep * smooth(np.clip(pattern, 0, 1)))

sweep = 0.5 * (1 + np.sin(2 * np.pi * t / 1.6 - np.pi / 2))
freq = 600 + 600 * sweep
phase = 2 * np.pi * np.cumsum(freq) / SR
save("siren", np.sin(phase) + 0.3 * np.sin(2 * phase))

rise_f = 400 + 1600 * ((t % 2.0) / 2.0)
rise_p = 2 * np.pi * np.cumsum(rise_f) / SR
save("rising_tone", (np.sin(rise_p) + 0.25 * np.sin(2 * rise_p)) * smooth(gate(t, 2.0, 1.8)))

bell_env = np.exp(-12 * (t % 0.12))
bell = tone(880, t, (1.0, 0.5, 0.3, 0.15)) * bell_env
save("alarm_bell", bell * smooth(gate(t, 1.5, 1.0)))

# --- Мелодии ---
notes = [523.25, 659.25, 783.99, 1046.5, 783.99, 659.25]  # до-ми-соль-до-соль-ми
out = np.zeros_like(t)
step = 0.35
for i in range(int(DURATION / step)):
    f = notes[i % len(notes)]
    start = int(i * step * SR)
    n = int(0.6 * SR)
    seg = np.arange(n) / SR
    env = np.exp(-4 * seg) * np.minimum(1, seg / 0.01)
    end = min(len(out), start + n)
    out[start:end] += (tone(f, seg, (1.0, 0.3, 0.1)) * env)[: end - start]
save("melody_morning", out)

penta = [523.25, 587.33, 659.25, 783.99, 880.0, 1046.5]
out = np.zeros_like(t)
pos = 0.0
while pos < DURATION - 1.5:
    f = penta[rng.integers(len(penta))]
    start = int(pos * SR)
    n = int(1.4 * SR)
    seg = np.arange(n) / SR
    env = np.exp(-2.8 * seg) * np.minimum(1, seg / 0.005)
    end = min(len(out), start + n)
    out[start:end] += (tone(f, seg, (1.0, 0.45, 0.2, 0.1)) * env)[: end - start]
    pos += float(rng.choice([0.25, 0.3, 0.4, 0.5]))
save("melody_chimes", out)

# --- Басы (основные тона плюс гармоники, иначе динамик телефона их не воспроизведёт) ---
pulse = 0.5 * (1 + np.sin(2 * np.pi * 2.0 * t - np.pi / 2))
save("bass_pulse", tone(110, t, (1.0, 0.8, 0.6, 0.4, 0.25)) * (0.25 + 0.75 * pulse))
throb = 0.5 * (1 + np.sin(2 * np.pi * 0.7 * t))
save("bass_deep", tone(70, t, (1.0, 0.9, 0.8, 0.6, 0.4, 0.3)) * (0.35 + 0.65 * throb))

# --- Шумы (с пульсацией, чтобы не воспринимались как фон для сна) ---
white = rng.standard_normal(len(t))
mod = 0.35 + 0.65 * smooth(gate(t, 1.0, 0.6), 30)
save("noise_white", white * mod)


def pink_noise(n):
    spectrum = np.fft.rfft(rng.standard_normal(n))
    f = np.arange(len(spectrum))
    f[0] = 1
    return np.fft.irfft(spectrum / np.sqrt(f), n)


save("noise_pink", pink_noise(len(t)) * mod)
brown = np.cumsum(rng.standard_normal(len(t)))
brown -= np.convolve(brown, np.ones(2000) / 2000, mode="same")
save("noise_brown", brown * mod)
