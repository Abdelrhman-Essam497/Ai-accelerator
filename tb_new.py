import os
import numpy as np
import tensorflow as tf
from tensorflow.keras.models import Sequential
from qkeras.utils import load_qmodel
import time

tf.config.run_functions_eagerly(True)

start = time.time()

print("--- PHASE 1: HARDWARE-ALIGNED EXTRACTION ---")
model_path = 'hybrid_model.h5'

full_model = load_qmodel(model_path)

# Extract Layer 1
qconv_layer = next(l for l in full_model.layers if 'q_conv2d' in l.name.lower())
raw_weights, raw_biases = qconv_layer.get_weights()

# THE FIX: Transpose from (H, W, In, Out) to (Out, In, H, W)
# This changes (3, 3, 1, 16) -> (16, 1, 3, 3).
# When flattened, it groups all 9 pixels of Filter 0 together!
weights_vhdl_format = raw_weights.transpose(3, 2, 0, 1).reshape(16, 9)

# Scale and Cast
w_hw = np.round(weights_vhdl_format * 128).astype(np.int8)
b_hw = np.round(raw_biases * 128).astype(np.int8)

def write_coe_file(filename, data_array):
    flat_data = data_array.flatten()
    with open(filename, "w") as f:
        f.write("memory_initialization_radix=10;\n")
        f.write("memory_initialization_vector=\n")
        data_strs = [str(x) for x in flat_data]
        f.write(",\n".join(data_strs) + ";\n")
    print(f"✅ Saved sequentially aligned parameters to {filename}")

write_coe_file("layer1_weights.coe", w_hw)
write_coe_file("layer1_biases.coe", b_hw)

# Extract Pi Model
start_idx = next(i for i, l in enumerate(full_model.layers) if 'batch_normalization' in l.name.lower())
pi_model = Sequential(full_model.layers[start_idx:])
pi_model.build(input_shape=(None, 31, 31, 16))

pi_model.save('pi_only_model.h5')
print("✅ Saved software layers to pi_only_model.h5")









import cv2
import matplotlib.pyplot as plt
import numpy as np
import os

print("--- PHASE 2: IMAGE PREPARATION ---")

# Simply change this variable to the image you want to test before running
image_path = "cat(3).jpeg" 

# Verify the file exists before trying to read it
if not os.path.exists(image_path):
    print(f"Error: Could not find '{image_path}'.")
    exit()

# Read the image
img = cv2.imread(image_path)
if img is None:
    print(f"Error: Could not decode '{image_path}'. Make sure it is a valid image.")
    exit()

# Convert to grayscale
gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)

# Resize to 64x64 and enforce the uint8 data type for the FPGA accelerator
test_image_uint8 = cv2.resize(gray, (64, 64), interpolation=cv2.INTER_AREA).astype(np.uint8)

print(f"Success! '{image_path}' is correctly formatted as a 64x64 uint8 array.")

# Save a preview (avoids the plt.show() crash over SSH)
plt.figure(figsize=(3, 3))
plt.imshow(test_image_uint8, cmap='gray')
plt.title("FPGA Input (64x64)")
plt.axis('off')
plt.savefig("processed_fpga_input.png")
print("Saved visual preview as 'processed_fpga_input.png'.")

# ... the rest of your script to send data to the FPGA continues here ...











# import numpy as np

print("--- PHASE 3: VHDL REFERENCE EXECUTION (FPGA) ---")

# ==========================================
# 1. COE LOADER & FORMATTING
# ==========================================
def load_coe(filename):
    with open(filename, 'r') as f:
        lines = f.readlines()
    start_idx = None
    for i, line in enumerate(lines):
        if 'memory_initialization_vector=' in line:
            start_idx = i + 1
            break
    values = []
    for line in lines[start_idx:]:
        line = line.strip()
        if line.endswith(';'):
            line = line[:-1]
        parts = line.split(',')
        for part in parts:
            part = part.strip()
            if part:
                values.append(int(part))
    return np.array(values, dtype=np.int8)

# Load and reshape
weights_9 = load_coe('layer1_weights.coe').reshape(16, 9)
biases = load_coe('layer1_biases.coe')

ref_weights = np.zeros((16, 10), dtype=np.int8)
ref_weights[:, :9] = weights_9
ref_weights[:, 9] = biases

# ==========================================
# 2. VHDL GOLDEN REFERENCE MATH
# ==========================================
def compute_fpga_math(image_uint8, weights_int8):
    act_out = np.zeros((16, 62, 62), dtype=np.uint8)
    pool_out = np.zeros((16, 31, 31), dtype=np.uint8)

    for f in range(16):
        w = weights_int8[f, 0:9].reshape((3, 3)).astype(np.int32)
        b = int(weights_int8[f, 9])

        for i in range(62):
            for j in range(62):
                window = image_uint8[i:i+3, j:j+3].astype(np.int32)
                mac_result = np.sum(window * w) + b
                mac_result >>= 7

                if mac_result < 0:
                    act_out[f, i, j] = 0
                elif mac_result > 255:
                    act_out[f, i, j] = 255
                else:
                    act_out[f, i, j] = mac_result

    for f in range(16):
        for i in range(31):
            for j in range(31):
                pool_window = act_out[f, i*2:i*2+2, j*2:j*2+2]
                pool_out[f, i, j] = np.max(pool_window)

    return act_out, pool_out

print("⚙️ Simulating FPGA Registers...")
act_out, fpga_final_output = compute_fpga_math(test_image_uint8, ref_weights)

# =====================================================================
# 🚨 THE HANDOFF DATA STRUCTURE 🚨
# Variable: fpga_final_output
# Type:     NumPy Array (np.ndarray)
# Dtype:    Unsigned 8-bit Integer (np.uint8)
# Shape:    (16, 31, 31) -> (Channels, Height, Width)
# Content:  15,376 individual byte values ranging from 0 to 255.
# This represents the exact physical byte stream that will be sent
# over the UART/SPI wire from the Basys 3 to the Raspberry Pi.
# =====================================================================
print(f"✅ FPGA Output Generated. Shape: {fpga_final_output.shape}, DataType: {fpga_final_output.dtype}")
















import os
# import numpy as np
from tensorflow.keras.models import load_model
import matplotlib.pyplot as plt

print("--- PHASE 4: RASPBERRY PI HANDOFF ---")

print("🧠 Loading Raspberry Pi Layer 2+...")
pi_model = load_model('/content/pi_only_model.h5')

# =====================================================================
# 🚨 RECEIVING THE HANDOFF DATA 🚨
# The Pi receives the (16, 31, 31) array of 8-bit integers.
# However, standard Keras models expect the "Channels" dimension to be
# at the very end. We must transpose the physical data from:
# (16 Channels, 31 Height, 31 Width) --> (31 Height, 31 Width, 16 Channels)
# =====================================================================
pi_ready_data = fpga_final_output.transpose(1, 2, 0)

# The Pi CPU takes the 8-bit integers and casts them to 32-bit floats
# (np.float32) and adds a "Batch" dimension of 1 at the beginning so
# TensorFlow can process it.
pi_input = pi_ready_data.astype(np.float32).reshape(1, 31, 31, 16)

print("🧠 Pi is calculating final classification...")
score = pi_model.predict(pi_input, verbose=0)[0][0]

# Visual Verification
plt.figure(figsize=(4, 4))
plt.imshow(pi_ready_data[:,:,0], cmap='viridis')
plt.title("FPGA Output (Filter 0) inside Pi RAM")
plt.axis('off')
plt.show()

print(f"Raw Confidence Score: {score:.4f}")
print("==========================================")
print("FINAL VERDICT: " + ("DOG 🐶" if score > 0.5 else "CAT 🐱"))
print("==========================================")
print("Time:", time.time() - start)