"""Automatic SAM2 segmentation and compact colored overlays for camera snapshots."""
import base64
import colorsys
from io import BytesIO
import time

import numpy as np
from PIL import Image

_generator = None


def render_masks(records, original_size, inference_size):
    """Large regions first so smaller, nested segments remain visible."""
    width, height = inference_size
    scale_x, scale_y = original_size[0] / width, original_size[1] / height
    overlay = np.zeros((height, width, 4), dtype=np.uint8)
    segments = []
    for record in sorted(records, key=lambda r: r['area'], reverse=True):
        mask = np.asarray(record['segmentation'], dtype=bool)
        if mask.shape != (height, width):
            raise ValueError('Automatic mask dimensions do not match the image.')
        if not mask.any():
            continue
        index = len(segments)
        color = tuple(round(c * 255) for c in colorsys.hsv_to_rgb((index * .61803398875) % 1, .72, 1))
        overlay[mask] = (*color, 140)
        interior = np.zeros_like(mask)
        interior[1:-1, 1:-1] = (mask[1:-1, 1:-1] & mask[:-2, 1:-1] & mask[2:, 1:-1]
                               & mask[1:-1, :-2] & mask[1:-1, 2:])
        overlay[mask & ~interior] = (*color, 240)
        x, y, w, h = record['bbox']
        segments.append({'id': index + 1, 'color': '#%02x%02x%02x' % color,
                         'area': round(float(record['area']) * scale_x * scale_y),
                         'bbox': [x * scale_x, y * scale_y, w * scale_x, h * scale_y],
                         'score': float(record['predicted_iou'])})
    png = BytesIO()
    Image.fromarray(overlay).save(png, format='PNG')
    return {'width': original_size[0], 'height': original_size[1],
            'inferenceWidth': width, 'inferenceHeight': height,
            'overlay': base64.b64encode(png.getvalue()).decode('ascii'), 'segments': segments}


def generate(image, model, device, lock):
    # Bound mask decoding memory: automatic generation evaluates many prompts
    # simultaneously, unlike the click-to-segment page's single point prompt.
    import torch
    from sam2.automatic_mask_generator import SAM2AutomaticMaskGenerator
    global _generator
    start = time.monotonic()
    image = image.convert('RGB')
    original_size = image.size
    image.thumbnail((1536, 1536), Image.Resampling.LANCZOS)
    with lock, torch.inference_mode(), torch.autocast('cuda', dtype=torch.bfloat16, enabled=device == 'cuda'):
        if _generator is None:
            _generator = SAM2AutomaticMaskGenerator(model, points_per_side=32,
                points_per_batch=16, crop_n_layers=0, min_mask_region_area=0)
        try:
            records = _generator.generate(np.asarray(image))
        finally:
            _generator.predictor.reset_predictor()
    result = render_masks(records, original_size, image.size)
    result['elapsedSeconds'] = time.monotonic() - start
    return result
