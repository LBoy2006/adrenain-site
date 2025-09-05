from PIL import Image
import os

input_dir = "."
output_dir = "."
new_size = (256, 256)  # новое разрешение (ширина, высота)

os.makedirs(output_dir, exist_ok=True)

for filename in os.listdir(input_dir):
    if filename.lower().endswith(".png"):
        img_path = os.path.join(input_dir, filename)
        img = Image.open(img_path)

        # Меняем размер
        # img_resized = img.resize(new_size, Image.Resampling.LANCZOS)

        # Сохраняем как WebP
        base_name = os.path.splitext(filename)[0]
        output_path = os.path.join(output_dir, base_name + ".webp")
        img.save(output_path, "webp", quality=100)

        print(f"✅ {filename} → {output_path} ({new_size[0]}x{new_size[1]})")
