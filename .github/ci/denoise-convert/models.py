"""The AI Denoise network (NAFNet-SIDD-width32, megvii-research/NAFNet, MIT), loaded strictly from pinned weights.
Replaced SCUNet on 20 Oct: SCUNet cleaned a little better (+1 dB on the owner's photo) but took over 2 s per tile on
an iPhone 17 Pro Max (4+ minutes for 24 MP); NAFNet is all convolutions, about a quarter of the work, and runs on the
Neural Engine. Owner: one model, consistently good and quick."""
import torch

from nafnet import NAFNet


def load(name, weights):
    if name != 'nafnet':
        raise SystemExit(f'unknown model {name}')
    # options/test/SIDD/NAFNet-width32.yml
    net = NAFNet(img_channel=3, width=32, middle_blk_num=12, enc_blk_nums=[2, 2, 4, 8], dec_blk_nums=[2, 2, 2, 2])
    state = torch.load(weights, map_location='cpu', weights_only=True)
    net.load_state_dict(state.get('params', state), strict=True)
    return net.eval()
