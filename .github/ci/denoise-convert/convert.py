"""Convert a denoising network to a Core ML package with a fixed square tile (the app runs it tile by tile).

Model: NAFNet-SIDD-width32 (megvii-research/NAFNet, MIT), weights pinned by revision and SHA-256 in fetch.py.
Input `image` and output `output`: float16 [1, 3, T, T], RGB in 0...1 (sRGB-encoded, like the SIDD phone photos it was trained on).
Usage: python convert.py nafnet <weights.pth> <tile> <out.mlpackage>
"""
import sys

import coremltools as ct
import numpy as np
import torch

import models


class Clamped(torch.nn.Module):
    def __init__(self, net):
        super().__init__()
        self.net = net

    def forward(self, image):
        return torch.clamp(self.net(image), 0, 1)


name, weights, tile, out = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
assert tile % 64 == 0
net = models.load(name, weights)
example = torch.rand(1, 3, tile, tile)
traced = torch.jit.trace(Clamped(net).eval(), example)
mlmodel = ct.convert(
    traced,
    convert_to='mlprogram',
    compute_precision=ct.precision.FLOAT16,
    minimum_deployment_target=ct.target.iOS17,
    inputs=[ct.TensorType(name='image', shape=(1, 3, tile, tile), dtype=np.float16)],
    outputs=[ct.TensorType(name='output', dtype=np.float16)],
)
mlmodel.short_description = f'{name} denoise, {tile} x {tile} tiles (converted in Lumen CI)'
mlmodel.save(out)
print('saved', out)
