import spidev
import time
import numpy as np
import sys
from PIL import Image
import matplotlib.pyplot as plt
from tensorflow.keras.models import load_model
import os

def load_coe(filename):
    """Load values from a .coe file into a numpy array of int8."""
    with open(filename, 'r') as f:
        lines = f.readlines()

    # Find the start of the vector
    start_idx = None
    for i, line in enumerate(lines):
        if 'memory_initialization_vector=' in line:
            start_idx = i + 1
            break

    if start_idx is None:
        raise ValueError(f"No memory_initialization_vector found in {filename}")

    # Collect all values
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

def load_image(image_path):
    """Load and convert image to 64x64 grayscale uint8 numpy array."""
    try:
        img = Image.open(image_path)
        # Convert to grayscale
        img_gray = img.convert('L')
        # Resize to 64x64
        img_resized = img_gray.resize((64, 64), Image.Resampling.LANCZOS)
        # Convert to numpy uint8 array
        img_array = np.array(img_resized, dtype=np.uint8)
        # # Show the image for verification
        # Image.fromarray(img_array).show()

        return img_array
    except Exception as e:
        raise ValueError(f"Failed to load image from {image_path}: {e}")

# ==========================================
# 1. SPI Configuration
# ==========================================
spi = spidev.SpiDev()
spi.open(0, 0)
spi.max_speed_hz = 8000000 # 800 kHz ensures sharp clock edges
spi.mode = 0b00           # Mode 0 matches the VHDL falling/rising edge logic

def send_data(data_list, chunk_size=4096):
    """Sends data over SPI in chunks to avoid buffer overflows."""
    for i in range(0, len(data_list), chunk_size):
        chunk = data_list[i:i+chunk_size]
        spi.xfer2(chunk)
#        time.sleep(0.001)

def receive_data(num_bytes, chunk_size=4096):
    """Clocks the SPI line to receive data from the FPGA."""
    received = []
    dummy_payload = [0x00] * chunk_size
    bytes_left = num_bytes
    while bytes_left > 0:
        to_read = min(bytes_left, chunk_size)
        chunk_data = spi.xfer2(dummy_payload[:to_read])
        received.extend(chunk_data)
        bytes_left -= to_read
 #       time.sleep(0.001)
    return received

def fpga_inference(image_path, weights_path='layer1_weights.coe', biases_path='layer1_bias.coe'):
    """
    Sends weights, biases, and image to FPGA and returns the output as a numpy array (16, 31, 31).
    """
    # Load weights and biases
    weights_9 = load_coe(weights_path).reshape(16, 9)
    biases = load_coe(biases_path)
    dummy_weights = np.zeros((16, 10), dtype=np.int8)
    dummy_weights[:, :9] = weights_9
    dummy_weights[:, 9] = biases

    # Load image
    dummy_image = load_image(image_path)

    # Flatten for SPI
    weights_payload = dummy_weights.view(np.int8).flatten().tolist()
    image_payload = dummy_image.flatten().tolist()

    # Send to FPGA
    send_data(weights_payload)
    send_data(image_payload)
    time.sleep(0.01)

    expected_bytes = 16 * 31 * 31
    pipeline_delay = 1
    raw_results = receive_data(expected_bytes + pipeline_delay)
    aligned_results = raw_results[1:]
    hardware_output = np.array(aligned_results, dtype=np.uint8).reshape((16, 31, 31))
    return hardware_output

def classify_with_pi_model(fpga_final_output, keras_model_path='pi_only_model.h5', image_filename=None):
#    print("--- PHASE 4: RASPBERRY PI HANDOFF ---")
#    print("🧠 Loading Raspberry Pi Layer 2+...")
    pi_model = load_model(keras_model_path)

    # Transpose to (31, 31, 16)
    pi_ready_data = fpga_final_output.transpose(1, 2, 0)
    pi_input = pi_ready_data.astype(np.float32).reshape(1, 31, 31, 16)

#    print("🧠 Pi is calculating final classification...")
    score = pi_model.predict(pi_input, verbose=0)[0][0]

    # Visual Verification
#    plt.figure(figsize=(4, 4))
#    plt.imshow(pi_ready_data[:,:,0], cmap='viridis')
#    plt.title("FPGA Output (Filter 0) inside Pi RAM")
#    plt.axis('off')
#    plt.show()

    print(f"Raw Confidence Score: {score:.4f}")
    print("==========================================")
    print("FINAL VERDICT: " + ("DOG 🐶" if score > 0.5 else "CAT 🐱"))
    print("==========================================")


def main():
    # ==========================================
    # 2. Test Data Generation
    # ==========================================
    print("--- Booting FPGA Hardware Verification ---")

    # A fixed seed ensures your hardware results perfectly match your PC's Python results
    np.random.seed(42)

    # Load weights and biases from COE files
    weights_9 = load_coe('layer1_weights.coe').reshape(16, 9)
    biases = load_coe('layer1_bias.coe')
    dummy_weights = np.zeros((16, 10), dtype=np.int8)
    dummy_weights[:, :9] = weights_9
    dummy_weights[:, 9] = biases

    try:
        # Load image from filesystem (64x64 grayscale)
        image_file = sys.argv[1] if len(sys.argv) > 1 else 'input_image.png'
#        print(f"Loading image from: {image_file}")
        output = fpga_inference(image_file)
#        print("\n[SUCCESS] Hardware processing complete and data aligned!")
#        print(f"Output Shape: {output.shape}")
#        for f in range(16):
#            print(f"\n==========================================")
#            print(f" FILTER {f} FULL OUTPUT (31x31)")
#            print(f"==========================================")
#            print(output[f])
        # Pi-side classification and visualization
        classify_with_pi_model(output, keras_model_path='pi_only_model.h5', image_filename=image_file)

    except Exception as e:
        print(f"Error occurred: {e}")
    finally:
        # Always release the SPI pins when the script ends
        spi.close()
        print("\nSPI connection safely closed.")

# CRITICAL: This line actually tells Python to run the main() function!
if __name__ == "__main__":
    start = time.time()
    main()
    print("Time:", time.time() - start)