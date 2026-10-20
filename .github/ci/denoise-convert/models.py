"""The AI Denoise network (SCUNet real-noise colour model, cszn/SCUNet, Apache-2.0), loaded strictly from pinned weights.
SCUNet was picked over NAFNet-SIDD-width32 on 20 Oct (owner's photo, added camera-like noise: +3.7/+4.7 dB, more detail)."""
import torch

from scunet import SCUNet


def load(name, weights):
    if name != 'scunet':
        raise SystemExit(f'unknown model {name}')
    # main_test_scunet_real_application.py: scunet_color_real_psnr
    net = SCUNet(in_nc=3, config=[4, 4, 4, 4, 4, 4, 4], dim=64)
    net.load_state_dict(torch.load(weights, map_location='cpu', weights_only=True), strict=True)
    return net.eval()
