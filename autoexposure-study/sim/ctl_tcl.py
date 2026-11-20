"""Controllers that mirror the proposed Folk program exactly: median across
tags, deadband 12 around 200, log-domain gain 0.6, max ratio 1.5,
clip-aware, no-tag sweep after 0.5s, and a `sleep 0.1` cadence (10 Hz =
every 3rd frame at 30 fps). _p10 models a slow machine where detection
itself only runs at ~3 Hz."""
from controllers import Proposal, ContrastProposal


def register(REGISTRY):
    REGISTRY["prop_tcl"] = lambda: Proposal("prop_tcl", aggregate="median", persist_frames=1,
                                            hold_frames=0, period_frames=3, lost_frames=5)
    REGISTRY["prop_tcl_p10"] = lambda: Proposal("prop_tcl_p10", aggregate="median", persist_frames=1,
                                                hold_frames=0, period_frames=10, lost_frames=2)
    REGISTRY["prop_tcl_lo1000"] = lambda: Proposal("prop_tcl_lo1000", aggregate="median", persist_frames=1,
                                                   hold_frames=0, period_frames=3, lost_frames=5, lo=1000)
    REGISTRY["prop_contrast_tcl"] = lambda: ContrastProposal("prop_contrast_tcl", persist_frames=1,
                                                             hold_frames=0, period_frames=3, lost_frames=5)
