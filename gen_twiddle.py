# -*- coding: utf-8 -*-
#!/usr/bin/env python3
"""
Generate 1024-point FFT twiddle factor ROM init file (twiddle_init.hex)
W_N^k = cos(2*pi*k/N) - j*sin(2*pi*k/N), k=0..N/2-1
Fixed-point Q1.15 signed, output 32-bit hex per line: {cos[15:0], -sin[15:0]}
"""

import math
import os

N = 1024
HALF_N = N // 2
FRAC_BITS = 15
SCALE = 2**FRAC_BITS  # 32768

def float_to_q15(val):
    """Convert float to Q1.15 fixed-point (16-bit signed)"""
    # Clamp to [-1, 1-2^-15]
    val = max(-1.0, min(val, 1.0 - 2**(-FRAC_BITS)))
    q = int(round(val * SCALE))
    # 钳位到16位有符号范围
    q = max(-32768, min(q, 32767))
    # Convert to unsigned 16-bit (two's complement)
    if q < 0:
        q = q + 65536
    return q

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    output_path = os.path.join(script_dir, "twiddle_init.hex")

    with open(output_path, "w") as f:
        for k in range(HALF_N):
            angle = 2.0 * math.pi * k / N
            cos_val = math.cos(angle)
            sin_val = -math.sin(angle)  # W = cos - j*sin, store -sin as imag part
            
            cos_q15 = float_to_q15(cos_val)
            sin_q15 = float_to_q15(sin_val)
            
            # Upper 16 bits = cos (real), Lower 16 bits = -sin (imag)
            word = (cos_q15 << 16) | sin_q15
            f.write(f"{word:08x}\n")

    print(f"Generated {HALF_N} twiddle factors -> {output_path}")

if __name__ == "__main__":
    main()
