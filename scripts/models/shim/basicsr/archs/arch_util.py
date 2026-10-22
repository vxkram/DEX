# The three helpers the upstream archs use, without BasicSR's CUDA extras.
import torch
from torch import nn
from torch.nn import init

@torch.no_grad()
def default_init_weights(module_list, scale=1, bias_fill=0, **kwargs):
    if not isinstance(module_list, list):
        module_list = [module_list]
    for module in module_list:
        for m in module.modules():
            if isinstance(m, (nn.Conv2d, nn.Linear)):
                init.kaiming_normal_(m.weight, **kwargs)
                m.weight.data *= scale
                if m.bias is not None:
                    m.bias.data.fill_(bias_fill)

def make_layer(basic_block, num_basic_block, **kwarg):
    return nn.Sequential(*[basic_block(**kwarg) for _ in range(num_basic_block)])

def pixel_unshuffle(x, scale):
    b, c, hh, hw = x.size()
    h, w = hh // scale, hw // scale
    x_view = x.view(b, c, h, scale, w, scale)
    return x_view.permute(0, 1, 3, 5, 2, 4).reshape(b, c * scale * scale, h, w)
