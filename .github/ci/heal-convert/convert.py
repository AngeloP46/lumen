"""Convert Big LaMa (IOPaint's TorchScript big-lama.pt, Apache-2.0) to a Core ML package at a fixed square size.

Same recipe as mallman/CoreMLaMa (and the 800 px mlboydaisuke/LaMa-CoreML the app used before): image in 0..255,
mask (anything above 0 = fill), output clamped 0..255, all float32 so the Fourier convolutions don't overflow.
Usage: python convert.py <side> <big-lama.pt> <out.mlpackage>
"""
import sys

import coremltools as ct
import torch


class CoreMLaMa(torch.nn.Module):
    def __init__(self, lama):
        super().__init__()
        self.lama = lama

    def forward(self, image, mask):
        normalized_mask = ((mask > 0) * 1).byte()
        return torch.clamp(self.lama(image, normalized_mask) * 255, min=0, max=255)


side, source, out = int(sys.argv[1]), sys.argv[2], sys.argv[3]
assert side % 8 == 0
lama = torch.jit.load(source, map_location='cpu').eval()
model = torch.jit.script(CoreMLaMa(lama).eval())
mlmodel = ct.convert(
    model,
    convert_to='mlprogram',
    compute_precision=ct.precision.FLOAT32,
    compute_units=ct.ComputeUnit.CPU_AND_GPU,
    minimum_deployment_target=ct.target.iOS17,
    inputs=[ct.ImageType(name='image', shape=(1, 3, side, side), scale=1 / 255.0),
            ct.ImageType(name='mask', shape=(1, 1, side, side), color_layout=ct.colorlayout.GRAYSCALE)],
    outputs=[ct.ImageType(name='output')],
    skip_model_load=True,
)
mlmodel.short_description = f'Big LaMa inpainting, {side} x {side} (converted in Lumen CI)'
mlmodel.save(out)
print('saved', out)
