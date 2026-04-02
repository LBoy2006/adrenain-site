from PIL import Image
import os

input_dir = "."
output_dir = "."
new_width = 2048  # новая ширина (высота рассчитывается пропорционально)

os.makedirs(output_dir, exist_ok=True)

for filename in os.listdir(input_dir):
    if filename.lower().endswith(".jpg"):
        img_path = os.path.join(input_dir, filename)
        img = Image.open(img_path)

        # Меняем размер (только ширина, высота пропорциональна)
        width_percent = new_width / float(img.size[0])
        new_height = int(float(img.size[1]) * width_percent)
        img_resized = img.resize((new_width, new_height), Image.Resampling.LANCZOS)

        # Сохраняем как WebP
        base_name = os.path.splitext(filename)[0]
        output_path = os.path.join(output_dir, base_name + ".webp")
        img_resized.save(output_path, "webp", quality=90)

        print(f"✅ {filename} → {output_path} ({new_width}x{new_height})")
