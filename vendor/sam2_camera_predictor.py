# Copyright (c) Meta Platforms, Inc. and affiliates.
# All rights reserved.

# This source code is licensed under the license found in the
# LICENSE file in the root directory of this source tree.

from collections import OrderedDict

import numpy as np

import torch
import torch.nn.functional as F

from tqdm import tqdm

from sam2.modeling.sam2_base import NO_OBJ_SCORE, SAM2Base
from sam2.utils.misc import concat_points, fill_holes_in_mask_scores

# torch._dynamo.config.capture_dynamic_output_shape_ops = True


class SAM2CameraPredictor(SAM2Base):
    """The predictor class to handle user interactions and manage inference states."""

    def __init__(
        self,
        fill_hole_area=0,
        # whether to apply non-overlapping constraints on the output object masks
        non_overlap_masks=False,
        # whether to clear non-conditioning memory of the surrounding frames (which may contain outdated information) after adding correction clicks;
        # note that this would only apply to *single-object tracking* unless `clear_non_cond_mem_for_multi_obj` is also set to True)
        clear_non_cond_mem_around_input=False,
        # whether to also clear non-conditioning memory of the surrounding frames (only effective when `clear_non_cond_mem_around_input` is True).
        clear_non_cond_mem_for_multi_obj=False,
        # if `add_all_frames_to_correct_as_cond` is True, later correction frames are
        # also added to the conditioning frame list.
        add_all_frames_to_correct_as_cond=False,
        **kwargs,
    ):
        super().__init__(**kwargs)
        self.fill_hole_area = fill_hole_area
        self.non_overlap_masks = non_overlap_masks
        self.clear_non_cond_mem_around_input = clear_non_cond_mem_around_input
        self.clear_non_cond_mem_for_multi_obj = clear_non_cond_mem_for_multi_obj
        self.add_all_frames_to_correct_as_cond = add_all_frames_to_correct_as_cond
        self.condition_state = {}
        self.frame_idx = 0

    ###
    def perpare_data(
        self,
        img,
        image_size=1024,
        img_mean=(0.485, 0.456, 0.406),
        img_std=(0.229, 0.224, 0.225),
    ):
        if isinstance(img, np.ndarray):
            height, width = img.shape[:2]
            img = torch.from_numpy(img).permute(2, 0, 1).float()
            img = F.interpolate(
                img[None],
                size=(image_size, image_size),
                mode="bilinear",
                align_corners=False,
            )[0]
            img = img / 255.0
        else:
            img_np = (
                np.array(img.convert("RGB").resize((image_size, image_size))) / 255.0
            )
            width, height = img.size
            img = torch.from_numpy(img_np).permute(2, 0, 1).float()

        img_mean = torch.tensor(img_mean, dtype=torch.float32)[:, None, None]
        img_std = torch.tensor(img_std, dtype=torch.float32)[:, None, None]
        img -= img_mean
        img /= img_std
        return img, width, height

    ###
    @torch.inference_mode()
    def load_first_frame(self, img):

        self.condition_state = self._init_state(
            offload_video_to_cpu=False, offload_state_to_cpu=False
        )
        self.frame_idx = 0
        img, width, height = self.perpare_data(img, image_size=self.image_size)
        self.condition_state["images"] = [img]
        self.condition_state["num_frames"] = len(self.condition_state["images"])
        self.condition_state["video_height"] = height
        self.condition_state["video_width"] = width
        self._get_image_feature(frame_idx=0, batch_size=1)

    @torch.inference_mode()
    def add_conditioning_frame(self, img):
        img, width, height = self.perpare_data(img, image_size=self.image_size)
        self.condition_state["images"].append(img)
        self.condition_state["num_frames"] = len(self.condition_state["images"])
        self._get_image_feature(
            frame_idx=self.condition_state["num_frames"] - 1, batch_size=1
        )

    @torch.inference_mode()
    def load_prompt_frame(self, img):
        """Load the current camera frame so it can receive prompts before tracking."""
        self.frame_idx += 1
        self.condition_state["num_frames"] = max(
            self.condition_state["num_frames"], self.frame_idx + 1
        )
        img, width, height = self.perpare_data(img, image_size=self.image_size)
        self.condition_state["video_height"] = height
        self.condition_state["video_width"] = width
        while len(self.condition_state["images"]) <= self.frame_idx:
            self.condition_state["images"].append(None)
        self.condition_state["images"][self.frame_idx] = img
        image = img.to(self.device).float().unsqueeze(0)
        backbone_out = self.forward_image(image)
        self.condition_state["cached_features"] = {
            self.frame_idx: (image, backbone_out)
        }
        return self.frame_idx

    def _raw_image_frames_to_keep(self):
        keep_frames = {self.frame_idx}
        for per_obj in self.condition_state.get("temp_output_dict_per_obj", {}).values():
            for output_dict in per_obj.values():
                for frame_idx, out in output_dict.items():
                    if out.get("maskmem_features") is None:
                        keep_frames.add(frame_idx)
        return keep_frames

    def _prune_stale_raw_images(self):
        """Drop raw camera-frame tensors once tracking memory has been encoded."""
        images = self.condition_state.get("images")
        if not images:
            return

        keep_frames = self._raw_image_frames_to_keep()
        for frame_idx in range(len(images)):
            if frame_idx not in keep_frames:
                images[frame_idx] = None

    ###
    def _init_state(
        self,
        offload_video_to_cpu=False,
        offload_state_to_cpu=False,
    ):
        self.condition_state = {}

        # whether to offload the video frames to CPU memory
        # turning on this option saves the GPU memory with only a very small overhead
        self.condition_state["offload_video_to_cpu"] = offload_video_to_cpu
        # whether to offload the inference state to CPU memory
        # turning on this option saves the GPU memory at the cost of a lower tracking fps
        # (e.g. in a test case of 768x768 model, fps dropped from 27 to 24 when tracking one object
        # and from 24 to 21 when tracking two objects)
        self.condition_state["offload_state_to_cpu"] = offload_state_to_cpu
        # the original video height and width, used for resizing final output scores

        self.condition_state["device"] = self.device
        if offload_state_to_cpu:
            self.condition_state["storage_device"] = torch.device("cpu")
        else:
            self.condition_state["storage_device"] = self.device
        # inputs on each frame
        self.condition_state["point_inputs_per_obj"] = {}
        self.condition_state["mask_inputs_per_obj"] = {}
        # visual features on a small number of recently visited frames for quick interactions
        self.condition_state["cached_features"] = {}
        # values that don't change across frames (so we only need to hold one copy of them)
        self.condition_state["constants"] = {}
        # mapping between client-side object id and model-side object index
        self.condition_state["obj_id_to_idx"] = OrderedDict()
        self.condition_state["obj_idx_to_id"] = OrderedDict()
        self.condition_state["obj_ids"] = []
        # Tracking results stored independently for each object.
        self.condition_state["output_dict_per_obj"] = {}
        # A temporary storage to hold new outputs when user interact with a frame
        # to add clicks or mask.
        self.condition_state["temp_output_dict_per_obj"] = {}
        # metadata for each tracking frame (e.g. which direction it's tracked)
        self.condition_state["frames_tracked_per_obj"] = {}
        return self.condition_state

    ###
    def _obj_id_to_idx(self, obj_id):
        """Map client-side object id to model-side object index."""
        obj_idx = self.condition_state["obj_id_to_idx"].get(obj_id, None)
        if obj_idx is not None:
            return obj_idx

        # The newer SAM2 video predictor handles each object independently while
        # sharing image features, so new objects can be added after tracking starts.
        obj_idx = len(self.condition_state["obj_id_to_idx"])
        self.condition_state["obj_id_to_idx"][obj_id] = obj_idx
        self.condition_state["obj_idx_to_id"][obj_idx] = obj_id
        self.condition_state["obj_ids"] = list(self.condition_state["obj_id_to_idx"])
        self.condition_state["point_inputs_per_obj"][obj_idx] = {}
        self.condition_state["mask_inputs_per_obj"][obj_idx] = {}
        self.condition_state["output_dict_per_obj"][obj_idx] = {
            "cond_frame_outputs": {},
            "non_cond_frame_outputs": {},
        }
        self.condition_state["temp_output_dict_per_obj"][obj_idx] = {
            "cond_frame_outputs": {},
            "non_cond_frame_outputs": {},
        }
        self.condition_state["frames_tracked_per_obj"][obj_idx] = {}
        return obj_idx

    def _obj_idx_to_id(self, obj_idx):
        """Map model-side object index to client-side object id."""
        return self.condition_state["obj_idx_to_id"][obj_idx]

    ###
    def _get_obj_num(self):
        """Get the total number of unique object ids received so far in this session."""
        return len(self.condition_state["obj_idx_to_id"])

    ###
    @torch.inference_mode()
    def add_new_prompt(
        self,
        frame_idx,
        obj_id,
        points=None,
        labels=None,
        bbox=None,
        clear_old_points=True,
        normalize_coords=True,
    ):
        """Add new points to a frame."""
        obj_idx = self._obj_id_to_idx(obj_id)
        point_inputs_per_frame = self.condition_state["point_inputs_per_obj"][obj_idx]
        mask_inputs_per_frame = self.condition_state["mask_inputs_per_obj"][obj_idx]

        assert (
            bbox is not None or points is not None
        ), "Either bbox or points is required"

        if points is None:
            points = torch.zeros(0, 2, dtype=torch.float32)
        elif not isinstance(points, torch.Tensor):
            points = torch.tensor(points, dtype=torch.float32)
        if labels is None:
            labels = torch.zeros(0, dtype=torch.int32)
        elif not isinstance(labels, torch.Tensor):
            labels = torch.tensor(labels, dtype=torch.int32)
        if points.dim() == 2:
            points = points.unsqueeze(0)  # add batch dimension
        if labels.dim() == 1:
            labels = labels.unsqueeze(0)  # add batch dimension
        if bbox is not None:
            if not isinstance(bbox, torch.Tensor):
                bbox = torch.tensor(bbox, dtype=torch.float32, device=points.device)
                box_coords = bbox.reshape(1, 2, 2)
                box_labels = torch.tensor(
                    [2, 3], dtype=torch.int32, device=labels.device
                )
                box_labels = box_labels.reshape(1, 2)
                points = torch.cat([box_coords, points], dim=1)
                labels = torch.cat([box_labels, labels], dim=1)
        if normalize_coords:
            video_H = self.condition_state["video_height"]
            video_W = self.condition_state["video_width"]
            points = points / torch.tensor([video_W, video_H]).to(points.device)
        # scale the (normalized) coordinates by the model's internal image size
        points = points * self.image_size
        points = points.to(self.condition_state["device"])
        labels = labels.to(self.condition_state["device"])

        if not clear_old_points:
            point_inputs = point_inputs_per_frame.get(frame_idx, None)
        else:
            point_inputs = None
        point_inputs = concat_points(point_inputs, points, labels)

        point_inputs_per_frame[frame_idx] = point_inputs
        mask_inputs_per_frame.pop(frame_idx, None)
        # If this frame hasn't been tracked before, we treat it as an initial conditioning
        # frame, meaning that the inputs points are to generate segments on this frame without
        # using any memory from other frames, like in SAM. Otherwise (if it has been tracked),
        # the input points will be used to correct the already tracked masks.
        obj_frames_tracked = self.condition_state["frames_tracked_per_obj"][obj_idx]
        is_init_cond_frame = frame_idx not in obj_frames_tracked
        # whether to track in reverse time order
        if is_init_cond_frame:
            reverse = False
        else:
            reverse = obj_frames_tracked[frame_idx]["reverse"]
        obj_output_dict = self.condition_state["output_dict_per_obj"][obj_idx]
        obj_temp_output_dict = self.condition_state["temp_output_dict_per_obj"][obj_idx]
        # Add a frame to conditioning output if it's an initial conditioning frame or
        # if the model sees all frames receiving clicks/mask as conditioning frames.
        is_cond = is_init_cond_frame or self.add_all_frames_to_correct_as_cond
        storage_key = "cond_frame_outputs" if is_cond else "non_cond_frame_outputs"

        # Get any previously predicted mask logits on this object and feed it along with
        # the new clicks into the SAM mask decoder.
        prev_sam_mask_logits = None
        # lookup temporary output dict first, which contains the most recent output
        # (if not found, then lookup conditioning and non-conditioning frame output)
        prev_out = obj_temp_output_dict[storage_key].get(frame_idx)
        if prev_out is None:
            prev_out = obj_output_dict["cond_frame_outputs"].get(frame_idx)
            if prev_out is None:
                prev_out = obj_output_dict["non_cond_frame_outputs"].get(frame_idx)

        if prev_out is not None and prev_out["pred_masks"] is not None:
            prev_sam_mask_logits = prev_out["pred_masks"].cuda(non_blocking=True)
            # Clamp the scale of prev_sam_mask_logits to avoid rare numerical issues.
            prev_sam_mask_logits = torch.clamp(prev_sam_mask_logits, -32.0, 32.0)
        current_out, _ = self._run_single_frame_inference(
            output_dict=obj_output_dict,  # run on the slice of a single object
            frame_idx=frame_idx,
            batch_size=1,  # run on the slice of a single object
            is_init_cond_frame=is_init_cond_frame,
            point_inputs=point_inputs,
            mask_inputs=None,
            reverse=reverse,
            # Skip the memory encoder when adding clicks or mask. We execute the memory encoder
            # at the beginning of `propagate_in_video` (after user finalize their clicks). This
            # allows us to enforce non-overlapping constraints on all objects before encoding
            # them into memory.
            run_mem_encoder=False,
            prev_sam_mask_logits=prev_sam_mask_logits,
        )
        # Add the output to the output dict (to be used as future memory)
        obj_temp_output_dict[storage_key][frame_idx] = current_out

        # Resize the output mask to the original video resolution
        obj_ids = self.condition_state["obj_ids"]
        consolidated_out = self._consolidate_temp_output_across_obj(
            frame_idx,
            is_cond=is_cond,
            run_mem_encoder=False,
            consolidate_at_video_res=True,
        )
        _, video_res_masks = self._get_orig_video_res_output(
            consolidated_out["pred_masks_video_res"]
        )
        return frame_idx, obj_ids, video_res_masks

    ###
    @torch.inference_mode()
    def add_new_points(
        self,
        frame_idx,
        obj_id,
        points,
        labels,
        clear_old_points=True,
        normalize_coords=True,
    ):
        """Add new points to a frame."""
        obj_idx = self._obj_id_to_idx(obj_id)
        point_inputs_per_frame = self.condition_state["point_inputs_per_obj"][obj_idx]
        mask_inputs_per_frame = self.condition_state["mask_inputs_per_obj"][obj_idx]

        if not isinstance(points, torch.Tensor):
            points = torch.tensor(points, dtype=torch.float32)
        if not isinstance(labels, torch.Tensor):
            labels = torch.tensor(labels, dtype=torch.int32)
        if points.dim() == 2:
            points = points.unsqueeze(0)  # add batch dimension
        if labels.dim() == 1:
            labels = labels.unsqueeze(0)  # add batch dimension
        if normalize_coords:
            video_H = self.condition_state["video_height"]
            video_W = self.condition_state["video_width"]
            points = points / torch.tensor([video_W, video_H]).to(points.device)
        # scale the (normalized) coordinates by the model's internal image size
        points = points * self.image_size
        points = points.to(self.condition_state["device"])
        labels = labels.to(self.condition_state["device"])

        if not clear_old_points:
            point_inputs = point_inputs_per_frame.get(frame_idx, None)
        else:
            point_inputs = None
        point_inputs = concat_points(point_inputs, points, labels)

        point_inputs_per_frame[frame_idx] = point_inputs
        mask_inputs_per_frame.pop(frame_idx, None)
        # If this frame hasn't been tracked before, we treat it as an initial conditioning
        # frame, meaning that the inputs points are to generate segments on this frame without
        # using any memory from other frames, like in SAM. Otherwise (if it has been tracked),
        # the input points will be used to correct the already tracked masks.
        obj_frames_tracked = self.condition_state["frames_tracked_per_obj"][obj_idx]
        is_init_cond_frame = frame_idx not in obj_frames_tracked
        # whether to track in reverse time order
        if is_init_cond_frame:
            reverse = False
        else:
            reverse = obj_frames_tracked[frame_idx]["reverse"]
        obj_output_dict = self.condition_state["output_dict_per_obj"][obj_idx]
        obj_temp_output_dict = self.condition_state["temp_output_dict_per_obj"][obj_idx]
        # Add a frame to conditioning output if it's an initial conditioning frame or
        # if the model sees all frames receiving clicks/mask as conditioning frames.
        is_cond = is_init_cond_frame or self.add_all_frames_to_correct_as_cond
        storage_key = "cond_frame_outputs" if is_cond else "non_cond_frame_outputs"

        # Get any previously predicted mask logits on this object and feed it along with
        # the new clicks into the SAM mask decoder.
        prev_sam_mask_logits = None
        # lookup temporary output dict first, which contains the most recent output
        # (if not found, then lookup conditioning and non-conditioning frame output)
        prev_out = obj_temp_output_dict[storage_key].get(frame_idx)
        if prev_out is None:
            prev_out = obj_output_dict["cond_frame_outputs"].get(frame_idx)
            if prev_out is None:
                prev_out = obj_output_dict["non_cond_frame_outputs"].get(frame_idx)

        if prev_out is not None and prev_out["pred_masks"] is not None:
            prev_sam_mask_logits = prev_out["pred_masks"].to(self.device, non_blocking=True)
            # Clamp the scale of prev_sam_mask_logits to avoid rare numerical issues.
            prev_sam_mask_logits = torch.clamp(prev_sam_mask_logits, -32.0, 32.0)
        current_out, _ = self._run_single_frame_inference(
            output_dict=obj_output_dict,  # run on the slice of a single object
            frame_idx=frame_idx,
            batch_size=1,  # run on the slice of a single object
            is_init_cond_frame=is_init_cond_frame,
            point_inputs=point_inputs,
            mask_inputs=None,
            reverse=reverse,
            # Skip the memory encoder when adding clicks or mask. We execute the memory encoder
            # at the beginning of `propagate_in_video` (after user finalize their clicks). This
            # allows us to enforce non-overlapping constraints on all objects before encoding
            # them into memory.
            run_mem_encoder=False,
            prev_sam_mask_logits=prev_sam_mask_logits,
        )
        # Add the output to the output dict (to be used as future memory)
        obj_temp_output_dict[storage_key][frame_idx] = current_out

        # Resize the output mask to the original video resolution
        obj_ids = self.condition_state["obj_ids"]
        consolidated_out = self._consolidate_temp_output_across_obj(
            frame_idx,
            is_cond=is_cond,
            run_mem_encoder=False,
            consolidate_at_video_res=True,
        )
        _, video_res_masks = self._get_orig_video_res_output(
            consolidated_out["pred_masks_video_res"]
        )
        return frame_idx, obj_ids, video_res_masks

    ###
    @torch.inference_mode()
    def add_new_mask(
        self,
        frame_idx,
        obj_id,
        mask,
    ):
        """Add new mask to a frame."""
        obj_idx = self._obj_id_to_idx(obj_id)
        point_inputs_per_frame = self.condition_state["point_inputs_per_obj"][obj_idx]
        mask_inputs_per_frame = self.condition_state["mask_inputs_per_obj"][obj_idx]

        if not isinstance(mask, torch.Tensor):
            mask = torch.tensor(mask, dtype=torch.bool)
        assert mask.dim() == 2
        mask_H, mask_W = mask.shape
        mask_inputs_orig = mask[None, None]  # add batch and channel dimension
        mask_inputs_orig = mask_inputs_orig.float().to(self.condition_state["device"])

        # resize the mask if it doesn't match the model's image size
        if mask_H != self.image_size or mask_W != self.image_size:
            mask_inputs = torch.nn.functional.interpolate(
                mask_inputs_orig,
                size=(self.image_size, self.image_size),
                align_corners=False,
                mode="bilinear",
                antialias=True,  # use antialias for downsampling
            )
            mask_inputs = (mask_inputs >= 0.5).float()
        else:
            mask_inputs = mask_inputs_orig

        mask_inputs_per_frame[frame_idx] = mask_inputs
        point_inputs_per_frame.pop(frame_idx, None)
        # If this frame hasn't been tracked before, we treat it as an initial conditioning
        # frame, meaning that the inputs points are to generate segments on this frame without
        # using any memory from other frames, like in SAM. Otherwise (if it has been tracked),
        # the input points will be used to correct the already tracked masks.
        obj_frames_tracked = self.condition_state["frames_tracked_per_obj"][obj_idx]
        is_init_cond_frame = frame_idx not in obj_frames_tracked
        # whether to track in reverse time order
        if is_init_cond_frame:
            reverse = False
        else:
            reverse = obj_frames_tracked[frame_idx]["reverse"]
        obj_output_dict = self.condition_state["output_dict_per_obj"][obj_idx]
        obj_temp_output_dict = self.condition_state["temp_output_dict_per_obj"][obj_idx]
        # Add a frame to conditioning output if it's an initial conditioning frame or
        # if the model sees all frames receiving clicks/mask as conditioning frames.
        is_cond = is_init_cond_frame or self.add_all_frames_to_correct_as_cond
        storage_key = "cond_frame_outputs" if is_cond else "non_cond_frame_outputs"

        current_out, _ = self._run_single_frame_inference(
            output_dict=obj_output_dict,  # run on the slice of a single object
            frame_idx=frame_idx,
            batch_size=1,  # run on the slice of a single object
            is_init_cond_frame=is_init_cond_frame,
            point_inputs=None,
            mask_inputs=mask_inputs,
            reverse=reverse,
            # Skip the memory encoder when adding clicks or mask. We execute the memory encoder
            # at the beginning of `propagate_in_video` (after user finalize their clicks). This
            # allows us to enforce non-overlapping constraints on all objects before encoding
            # them into memory.
            run_mem_encoder=False,
        )
        # Add the output to the output dict (to be used as future memory)
        obj_temp_output_dict[storage_key][frame_idx] = current_out

        # Resize the output mask to the original video resolution
        obj_ids = self.condition_state["obj_ids"]
        consolidated_out = self._consolidate_temp_output_across_obj(
            frame_idx,
            is_cond=is_cond,
            run_mem_encoder=False,
            consolidate_at_video_res=True,
        )
        _, video_res_masks = self._get_orig_video_res_output(
            consolidated_out["pred_masks_video_res"]
        )
        return frame_idx, obj_ids, video_res_masks

    ###
    def _get_orig_video_res_output(self, any_res_masks):
        """
        Resize the object scores to the original video resolution (video_res_masks)
        and apply non-overlapping constraints for final output.
        """
        device = self.condition_state["device"]
        video_H = self.condition_state["video_height"]
        video_W = self.condition_state["video_width"]
        any_res_masks = any_res_masks.to(device, non_blocking=True)
        if any_res_masks.shape[-2:] == (video_H, video_W):
            video_res_masks = any_res_masks
        else:
            video_res_masks = torch.nn.functional.interpolate(
                any_res_masks,
                size=(video_H, video_W),
                mode="bilinear",
                align_corners=False,
            )
        if self.non_overlap_masks:
            video_res_masks = self._apply_non_overlapping_constraints(video_res_masks)
        return any_res_masks, video_res_masks

    def _consolidate_temp_output_across_obj(
        self,
        frame_idx,
        is_cond,
        run_mem_encoder,
        consolidate_at_video_res=False,
    ):
        """
        Consolidate the per-object temporary outputs in `temp_output_dict_per_obj` on
        a frame into a single output for all objects, including
        1) fill any missing objects either from `output_dict_per_obj` (if they exist in
           `output_dict_per_obj` for this frame) or leave them as placeholder values
           (if they don't exist in `output_dict_per_obj` for this frame);
        2) if specified, rerun memory encoder after apply non-overlapping constraints
           on the object scores.
        """
        batch_size = self._get_obj_num()
        storage_key = "cond_frame_outputs" if is_cond else "non_cond_frame_outputs"
        # Optionally, we allow consolidating the temporary outputs at the original
        # video resolution (to provide a better editing experience for mask prompts).
        if consolidate_at_video_res:
            assert not run_mem_encoder, "memory encoder cannot run at video resolution"
            consolidated_H = self.condition_state["video_height"]
            consolidated_W = self.condition_state["video_width"]
            consolidated_mask_key = "pred_masks_video_res"
        else:
            consolidated_H = consolidated_W = self.image_size // 4
            consolidated_mask_key = "pred_masks"

        # Initialize `consolidated_out`. Its "maskmem_features" and "maskmem_pos_enc"
        # will be added when rerunning the memory encoder after applying non-overlapping
        # constraints to object scores. Its "pred_masks" are prefilled with a large
        # negative value (NO_OBJ_SCORE) to represent missing objects.
        consolidated_out = {
            "maskmem_features": None,
            "maskmem_pos_enc": None,
            consolidated_mask_key: torch.full(
                size=(batch_size, 1, consolidated_H, consolidated_W),
                fill_value=NO_OBJ_SCORE,
                dtype=torch.float32,
                device=self.condition_state["storage_device"],
            ),
            "obj_ptr": torch.full(
                size=(batch_size, self.hidden_dim),
                fill_value=NO_OBJ_SCORE,
                dtype=torch.float32,
                device=self.condition_state["device"],
            ),
            "object_score_logits": torch.full(
                size=(batch_size, 1),
                # default to 10.0 for object_score_logits, i.e. assuming the object is
                # present as sigmoid(10)=1, same as in `predict_masks` of `MaskDecoder`
                fill_value=10.0,
                dtype=torch.float32,
                device=self.condition_state["device"],
            ),
        }
        empty_mask_ptr = None
        for obj_idx in range(batch_size):
            obj_temp_output_dict = self.condition_state["temp_output_dict_per_obj"][
                obj_idx
            ]
            obj_output_dict = self.condition_state["output_dict_per_obj"][obj_idx]
            out = obj_temp_output_dict[storage_key].get(frame_idx, None)
            # If the object doesn't appear in "temp_output_dict_per_obj" on this frame,
            # we fall back and look up its previous output in "output_dict_per_obj".
            # We look up both "cond_frame_outputs" and "non_cond_frame_outputs" in
            # "output_dict_per_obj" to find a previous output for this object.
            if out is None:
                out = obj_output_dict["cond_frame_outputs"].get(frame_idx, None)
            if out is None:
                out = obj_output_dict["non_cond_frame_outputs"].get(frame_idx, None)
            # If the object doesn't appear in "output_dict_per_obj" either, we skip it
            # and leave its mask scores to the default scores (i.e. the NO_OBJ_SCORE
            # placeholder above) and set its object pointer to be a dummy pointer.
            if out is None:
                # Fill in dummy object pointers for those objects without any inputs or
                # tracking outcomes on this frame (only do it under `run_mem_encoder=True`,
                # i.e. when we need to build the memory for tracking).
                if run_mem_encoder:
                    if empty_mask_ptr is None:
                        empty_mask_ptr = self._get_empty_mask_ptr(frame_idx)
                    # fill object pointer with a dummy pointer (based on an empty mask)
                    consolidated_out["obj_ptr"][obj_idx : obj_idx + 1] = empty_mask_ptr
                continue
            # Add the temporary object output mask to consolidated output mask
            obj_mask = out["pred_masks"]
            consolidated_pred_masks = consolidated_out[consolidated_mask_key]
            if obj_mask.shape[-2:] == consolidated_pred_masks.shape[-2:]:
                consolidated_pred_masks[obj_idx : obj_idx + 1] = obj_mask
            else:
                # Resize first if temporary object mask has a different resolution
                resized_obj_mask = torch.nn.functional.interpolate(
                    obj_mask,
                    size=consolidated_pred_masks.shape[-2:],
                    mode="bilinear",
                    align_corners=False,
                )
                consolidated_pred_masks[obj_idx : obj_idx + 1] = resized_obj_mask
            consolidated_out["obj_ptr"][obj_idx : obj_idx + 1] = out["obj_ptr"]
            consolidated_out["object_score_logits"][obj_idx : obj_idx + 1] = out[
                "object_score_logits"
            ]

        # Optionally, apply non-overlapping constraints on the consolidated scores
        # and rerun the memory encoder
        if run_mem_encoder:
            device = self.condition_state["device"]
            high_res_masks = torch.nn.functional.interpolate(
                consolidated_out["pred_masks"].to(device, non_blocking=True),
                size=(self.image_size, self.image_size),
                mode="bilinear",
                align_corners=False,
            )
            if self.non_overlap_masks_for_mem_enc:
                high_res_masks = self._apply_non_overlapping_constraints(high_res_masks)
            maskmem_features, maskmem_pos_enc = self._run_memory_encoder(
                frame_idx=frame_idx,
                batch_size=batch_size,
                high_res_masks=high_res_masks,
                object_score_logits=consolidated_out["object_score_logits"],
                is_mask_from_pts=True,  # these frames are what the user interacted with
            )
            consolidated_out["maskmem_features"] = maskmem_features
            consolidated_out["maskmem_pos_enc"] = maskmem_pos_enc

        return consolidated_out

    def _get_empty_mask_ptr(self, frame_idx):
        """Get a dummy object pointer based on an empty mask on the current frame."""
        # A dummy (empty) mask with a single object
        batch_size = 1
        mask_inputs = torch.zeros(
            (batch_size, 1, self.image_size, self.image_size),
            dtype=torch.float32,
            device=self.condition_state["device"],
        )

        # Retrieve correct image features
        (
            _,
            _,
            current_vision_feats,
            current_vision_pos_embeds,
            feat_sizes,
        ) = self._get_image_feature(frame_idx, batch_size)

        # Feed the empty mask and image feature above to get a dummy object pointer
        current_out = self.track_step(
            frame_idx=frame_idx,
            is_init_cond_frame=True,
            current_vision_feats=current_vision_feats,
            current_vision_pos_embeds=current_vision_pos_embeds,
            feat_sizes=feat_sizes,
            point_inputs=None,
            mask_inputs=mask_inputs,
            output_dict={},
            num_frames=self.condition_state["num_frames"],
            track_in_reverse=False,
            run_mem_encoder=False,
            prev_sam_mask_logits=None,
        )
        return current_out["obj_ptr"]

    ###
    @torch.inference_mode()
    def propagate_in_video_preflight(self):
        """Prepare self.condition_state and consolidate temporary outputs before tracking."""
        batch_size = self._get_obj_num()
        if batch_size == 0:
            raise RuntimeError(
                "No input points or masks are provided for any object; please add inputs first."
            )

        for obj_idx in range(batch_size):
            obj_output_dict = self.condition_state["output_dict_per_obj"][obj_idx]
            obj_temp_output_dict = self.condition_state["temp_output_dict_per_obj"][
                obj_idx
            ]
            for is_cond in [False, True]:
                storage_key = "cond_frame_outputs" if is_cond else "non_cond_frame_outputs"
                for frame_idx, out in obj_temp_output_dict[storage_key].items():
                    if out["maskmem_features"] is None:
                        high_res_masks = torch.nn.functional.interpolate(
                            out["pred_masks"].to(self.condition_state["device"]),
                            size=(self.image_size, self.image_size),
                            mode="bilinear",
                            align_corners=False,
                        )
                        maskmem_features, maskmem_pos_enc = self._run_memory_encoder(
                            frame_idx=frame_idx,
                            batch_size=1,
                            high_res_masks=high_res_masks,
                            object_score_logits=out["object_score_logits"],
                            is_mask_from_pts=True,
                        )
                        out["maskmem_features"] = maskmem_features
                        out["maskmem_pos_enc"] = maskmem_pos_enc

                    obj_output_dict[storage_key][frame_idx] = out
                    if self.clear_non_cond_mem_around_input:
                        self._clear_non_cond_mem_around_input(frame_idx, obj_idx)

                obj_temp_output_dict[storage_key].clear()

            if len(obj_output_dict["cond_frame_outputs"]) == 0:
                obj_id = self._obj_idx_to_id(obj_idx)
                raise RuntimeError(
                    f"No input points or masks are provided for object id {obj_id}; please add inputs first."
                )
            for frame_idx in obj_output_dict["cond_frame_outputs"]:
                obj_output_dict["non_cond_frame_outputs"].pop(frame_idx, None)

        self._prune_stale_raw_images()

    def add_new_prompt_during_track(
        self,
        point=None,
        bbox=None,
        mask=None,
        if_new_target=True,
        obj_id=None,
        labels=None,
        clear_old_points=True,
    ):
        if obj_id is None:
            if if_new_target:
                obj_id = self.condition_state["obj_ids"][-1] + 1
            else:
                obj_id = self.condition_state["obj_ids"][-1]

        frame_idx = self.frame_idx

        if point is not None or bbox is not None:
            frame_idx, obj_ids, video_res_masks = self.add_new_prompt(
                frame_idx,
                obj_id,
                points=point,
                bbox=bbox,
                labels=labels,
                clear_old_points=clear_old_points,
                normalize_coords=True,
            )
        else:
            frame_idx, obj_ids, video_res_masks = self.add_new_mask(
                frame_idx, obj_id, mask
            )

        return frame_idx, obj_ids, video_res_masks

    ###
    @torch.inference_mode()
    def track(
        self,
        img,
    ):
        self.load_prompt_frame(img)
        return self.track_current_frame()

    @torch.inference_mode()
    def track_current_frame(self):
        """Track all objects on the already-loaded current camera frame."""
        self.propagate_in_video_preflight()

        obj_ids = self.condition_state["obj_ids"]
        batch_size = self._get_obj_num()
        pred_masks_per_obj = [None] * batch_size

        for obj_idx in range(batch_size):
            obj_output_dict = self.condition_state["output_dict_per_obj"][obj_idx]
            if self.frame_idx in obj_output_dict["cond_frame_outputs"]:
                storage_key = "cond_frame_outputs"
                current_out = obj_output_dict[storage_key][self.frame_idx]
                pred_masks = current_out["pred_masks"].to(
                    self.condition_state["device"], non_blocking=True
                )
                if self.clear_non_cond_mem_around_input:
                    self._clear_non_cond_mem_around_input(self.frame_idx, obj_idx)
            else:
                storage_key = "non_cond_frame_outputs"
                current_out, pred_masks = self._run_single_frame_inference(
                    output_dict=obj_output_dict,
                    frame_idx=self.frame_idx,
                    batch_size=1,
                    is_init_cond_frame=False,
                    point_inputs=None,
                    mask_inputs=None,
                    reverse=False,
                    run_mem_encoder=True,
                )
                obj_output_dict[storage_key][self.frame_idx] = current_out
                self._manage_memory_obj(obj_idx)

            self.condition_state["frames_tracked_per_obj"][obj_idx][self.frame_idx] = {
                "reverse": False
            }
            pred_masks_per_obj[obj_idx] = pred_masks

        if len(pred_masks_per_obj) > 1:
            all_pred_masks = torch.cat(pred_masks_per_obj, dim=0)
        else:
            all_pred_masks = pred_masks_per_obj[0]
        _, video_res_masks = self._get_orig_video_res_output(all_pred_masks)
        self._prune_stale_raw_images()
        return obj_ids, video_res_masks

    ###
    def _manage_memory_obj(self, obj_idx):
        non_cond_frame_outputs = self.condition_state["output_dict_per_obj"][obj_idx][
            "non_cond_frame_outputs"
        ]
        key_list = [key for key in non_cond_frame_outputs]
        #! TODO: better way to manage memory
        if len(non_cond_frame_outputs) > self.num_maskmem:
            for t in range(0, len(non_cond_frame_outputs) - self.num_maskmem):
                # key, Value = non_cond_frame_outputs.popitem(last=False)
                _ = non_cond_frame_outputs.pop(key_list[t], None)

    @torch.inference_mode()
    def propagate_in_video(
        self,
        start_frame_idx=None,
        max_frame_num_to_track=None,
        reverse=False,
    ):
        """Propagate the input points across frames to track in the entire video."""

        self.propagate_in_video_preflight()

        obj_ids = self.condition_state["obj_ids"]
        num_frames = self.condition_state["num_frames"]
        batch_size = self._get_obj_num()

        # set start index, end index, and processing order
        if start_frame_idx is None:
            # default: start from the earliest frame with input points
            start_frame_idx = min(
                t
                for obj_output_dict in self.condition_state[
                    "output_dict_per_obj"
                ].values()
                for t in obj_output_dict["cond_frame_outputs"]
            )
        if max_frame_num_to_track is None:
            # default: track all the frames in the video
            max_frame_num_to_track = num_frames
        if reverse:
            end_frame_idx = max(start_frame_idx - max_frame_num_to_track, 0)
            if start_frame_idx > 0:
                processing_order = range(start_frame_idx, end_frame_idx - 1, -1)
            else:
                processing_order = []  # skip reverse tracking if starting from frame 0
        else:
            end_frame_idx = min(
                start_frame_idx + max_frame_num_to_track, num_frames - 1
            )
            processing_order = range(start_frame_idx, end_frame_idx + 1)

        for frame_idx in tqdm(processing_order, desc="propagate in video"):
            pred_masks_per_obj = [None] * batch_size
            for obj_idx in range(batch_size):
                obj_output_dict = self.condition_state["output_dict_per_obj"][obj_idx]
                if frame_idx in obj_output_dict["cond_frame_outputs"]:
                    current_out = obj_output_dict["cond_frame_outputs"][frame_idx]
                    pred_masks = current_out["pred_masks"].to(
                        self.condition_state["device"], non_blocking=True
                    )
                    if self.clear_non_cond_mem_around_input:
                        self._clear_non_cond_mem_around_input(frame_idx, obj_idx)
                else:
                    current_out, pred_masks = self._run_single_frame_inference(
                        output_dict=obj_output_dict,
                        frame_idx=frame_idx,
                        batch_size=1,
                        is_init_cond_frame=False,
                        point_inputs=None,
                        mask_inputs=None,
                        reverse=reverse,
                        run_mem_encoder=True,
                    )
                    obj_output_dict["non_cond_frame_outputs"][frame_idx] = current_out

                self.condition_state["frames_tracked_per_obj"][obj_idx][frame_idx] = {
                    "reverse": reverse
                }
                pred_masks_per_obj[obj_idx] = pred_masks

            # Resize the output mask to the original video resolution (we directly use
            # the mask scores on GPU for output to avoid any CPU conversion in between)
            if len(pred_masks_per_obj) > 1:
                all_pred_masks = torch.cat(pred_masks_per_obj, dim=0)
            else:
                all_pred_masks = pred_masks_per_obj[0]
            _, video_res_masks = self._get_orig_video_res_output(all_pred_masks)
            yield frame_idx, obj_ids, video_res_masks

    def _add_output_per_object(self, frame_idx, current_out, storage_key):
        """
        Split a multi-object output into per-object output slices and add them into
        `output_dict_per_obj`. The resulting slices share the same tensor storage.
        """
        maskmem_features = current_out["maskmem_features"]
        assert maskmem_features is None or isinstance(maskmem_features, torch.Tensor)

        maskmem_pos_enc = current_out["maskmem_pos_enc"]
        assert maskmem_pos_enc is None or isinstance(maskmem_pos_enc, list)

        output_dict_per_obj = self.condition_state["output_dict_per_obj"]
        for obj_idx, obj_output_dict in output_dict_per_obj.items():
            obj_slice = slice(obj_idx, obj_idx + 1)
            obj_out = {
                "maskmem_features": None,
                "maskmem_pos_enc": None,
                "pred_masks": current_out["pred_masks"][obj_slice],
                "obj_ptr": current_out["obj_ptr"][obj_slice],
                "object_score_logits": current_out["object_score_logits"][obj_slice],
            }
            if maskmem_features is not None:
                obj_out["maskmem_features"] = maskmem_features[obj_slice]
            if maskmem_pos_enc is not None:
                obj_out["maskmem_pos_enc"] = [x[obj_slice] for x in maskmem_pos_enc]
            obj_output_dict[storage_key][frame_idx] = obj_out

    @torch.inference_mode()
    def reset_state(self):
        """Remove all input points or mask in all frames throughout the video."""
        self._reset_tracking_results()
        # Remove all object ids
        self.condition_state["obj_id_to_idx"].clear()
        self.condition_state["obj_idx_to_id"].clear()
        self.condition_state["obj_ids"].clear()
        self.condition_state["point_inputs_per_obj"].clear()
        self.condition_state["mask_inputs_per_obj"].clear()
        self.condition_state["output_dict_per_obj"].clear()
        self.condition_state["temp_output_dict_per_obj"].clear()
        self.condition_state["frames_tracked_per_obj"].clear()

    def _reset_tracking_results(self):
        """Reset all tracking inputs and results across the videos."""
        for v in self.condition_state["point_inputs_per_obj"].values():
            v.clear()
        for v in self.condition_state["mask_inputs_per_obj"].values():
            v.clear()
        for v in self.condition_state["output_dict_per_obj"].values():
            v["cond_frame_outputs"].clear()
            v["non_cond_frame_outputs"].clear()
        for v in self.condition_state["temp_output_dict_per_obj"].values():
            v["cond_frame_outputs"].clear()
            v["non_cond_frame_outputs"].clear()
        for v in self.condition_state["frames_tracked_per_obj"].values():
            v.clear()

    def _get_image_feature(self, frame_idx, batch_size):
        """Compute the image features on a given frame."""
        # Look up in the cache first
        image, backbone_out = self.condition_state["cached_features"].get(
            frame_idx, (None, None)
        )
        if backbone_out is None:
            # Cache miss -- we will run inference on a single image
            image = (
                self.condition_state["images"][frame_idx].to(self.device).float().unsqueeze(0)
            )
            backbone_out = self.forward_image(image)
            # Cache the most recent frame's feature (for repeated interactions with
            # a frame; we can use an LRU cache for more frames in the future).
            self.condition_state["cached_features"] = {frame_idx: (image, backbone_out)}

        # expand the features to have the same dimension as the number of objects
        expanded_image = image.expand(batch_size, -1, -1, -1)
        expanded_backbone_out = {
            "backbone_fpn": backbone_out["backbone_fpn"].copy(),
            "vision_pos_enc": backbone_out["vision_pos_enc"].copy(),
        }
        for i, feat in enumerate(expanded_backbone_out["backbone_fpn"]):
            expanded_backbone_out["backbone_fpn"][i] = feat.expand(
                batch_size, -1, -1, -1
            )
        for i, pos in enumerate(expanded_backbone_out["vision_pos_enc"]):
            pos = pos.expand(batch_size, -1, -1, -1)
            expanded_backbone_out["vision_pos_enc"][i] = pos

        features = self._prepare_backbone_features(expanded_backbone_out)
        features = (expanded_image,) + features
        return features

    ###
    def _get_feature(self, img, batch_size):
        image = img.to(self.device).float().unsqueeze(0)
        backbone_out = self.forward_image(image)
        expanded_image = image.expand(batch_size, -1, -1, -1)
        expanded_backbone_out = {
            "backbone_fpn": backbone_out["backbone_fpn"].copy(),
            "vision_pos_enc": backbone_out["vision_pos_enc"].copy(),
        }
        for i, feat in enumerate(expanded_backbone_out["backbone_fpn"]):
            expanded_backbone_out["backbone_fpn"][i] = feat.expand(
                batch_size, -1, -1, -1
            )
        for i, pos in enumerate(expanded_backbone_out["vision_pos_enc"]):
            pos = pos.expand(batch_size, -1, -1, -1)
            expanded_backbone_out["vision_pos_enc"][i] = pos

        features = self._prepare_backbone_features(expanded_backbone_out)
        features = (expanded_image,) + features
        return features

    def _run_single_frame_inference(
        self,
        output_dict,
        frame_idx,
        batch_size,
        is_init_cond_frame,
        point_inputs,
        mask_inputs,
        reverse,
        run_mem_encoder,
        prev_sam_mask_logits=None,
    ):
        """Run tracking on a single frame based on current inputs and previous memory."""
        # Retrieve correct image features
        (
            _,
            _,
            current_vision_feats,
            current_vision_pos_embeds,
            feat_sizes,
        ) = self._get_image_feature(frame_idx, batch_size)

        # point and mask should not appear as input simultaneously on the same frame
        assert point_inputs is None or mask_inputs is None
        current_out = self.track_step(
            frame_idx=frame_idx,
            is_init_cond_frame=is_init_cond_frame,
            current_vision_feats=current_vision_feats,
            current_vision_pos_embeds=current_vision_pos_embeds,
            feat_sizes=feat_sizes,
            point_inputs=point_inputs,
            mask_inputs=mask_inputs,
            output_dict=output_dict,
            num_frames=self.condition_state["num_frames"],
            track_in_reverse=reverse,
            run_mem_encoder=run_mem_encoder,
            prev_sam_mask_logits=prev_sam_mask_logits,
        )

        # optionally offload the output to CPU memory to save GPU space
        storage_device = self.condition_state["storage_device"]
        maskmem_features = current_out["maskmem_features"]
        if maskmem_features is not None:
            maskmem_features = maskmem_features.to(torch.bfloat16)
            maskmem_features = maskmem_features.to(storage_device, non_blocking=True)
        pred_masks_gpu = current_out["pred_masks"]
        # potentially fill holes in the predicted masks
        if self.fill_hole_area > 0:
            pred_masks_gpu = fill_holes_in_mask_scores(
                pred_masks_gpu, self.fill_hole_area
            )
        pred_masks = pred_masks_gpu.to(storage_device, non_blocking=True)
        # "maskmem_pos_enc" is the same across frames, so we only need to store one copy of it
        maskmem_pos_enc = self._get_maskmem_pos_enc(current_out)
        # object pointer is a small tensor, so we always keep it on GPU memory for fast access
        obj_ptr = current_out["obj_ptr"]
        object_score_logits = current_out["object_score_logits"]
        # make a compact version of this frame's output to reduce the state size
        compact_current_out = {
            "maskmem_features": maskmem_features,
            "maskmem_pos_enc": maskmem_pos_enc,
            "pred_masks": pred_masks,
            "obj_ptr": obj_ptr,
            "object_score_logits": object_score_logits,
        }
        return compact_current_out, pred_masks_gpu

    def _run_memory_encoder(
        self,
        frame_idx,
        batch_size,
        high_res_masks,
        object_score_logits,
        is_mask_from_pts,
    ):
        """
        Run the memory encoder on `high_res_masks`. This is usually after applying
        non-overlapping constraints to object scores. Since their scores changed, their
        memory also need to be computed again with the memory encoder.
        """
        # Retrieve correct image features
        _, _, current_vision_feats, _, feat_sizes = self._get_image_feature(
            frame_idx, batch_size
        )
        maskmem_features, maskmem_pos_enc = self._encode_new_memory(
            current_vision_feats=current_vision_feats,
            feat_sizes=feat_sizes,
            pred_masks_high_res=high_res_masks,
            object_score_logits=object_score_logits,
            is_mask_from_pts=is_mask_from_pts,
        )

        # optionally offload the output to CPU memory to save GPU space
        storage_device = self.condition_state["storage_device"]
        maskmem_features = maskmem_features.to(torch.bfloat16)
        maskmem_features = maskmem_features.to(storage_device, non_blocking=True)
        # "maskmem_pos_enc" is the same across frames, so we only need to store one copy of it
        maskmem_pos_enc = self._get_maskmem_pos_enc(
            {"maskmem_pos_enc": maskmem_pos_enc}
        )
        return maskmem_features, maskmem_pos_enc

    def _get_maskmem_pos_enc(self, current_out):
        """
        `maskmem_pos_enc` is the same across frames and objects, so we cache it as
        a constant in the inference session to reduce session storage size.
        """
        model_constants = self.condition_state["constants"]
        # "out_maskmem_pos_enc" should be either a list of tensors or None
        out_maskmem_pos_enc = current_out["maskmem_pos_enc"]
        if out_maskmem_pos_enc is not None:
            if "maskmem_pos_enc" not in model_constants:
                assert isinstance(out_maskmem_pos_enc, list)
                # only take the slice for one object, since it's same across objects
                maskmem_pos_enc = [x[0:1].clone() for x in out_maskmem_pos_enc]
                model_constants["maskmem_pos_enc"] = maskmem_pos_enc
            else:
                maskmem_pos_enc = model_constants["maskmem_pos_enc"]
            # expand the cached maskmem_pos_enc to the actual batch size
            batch_size = out_maskmem_pos_enc[0].size(0)
            expanded_maskmem_pos_enc = [
                x.expand(batch_size, -1, -1, -1) for x in maskmem_pos_enc
            ]
        else:
            expanded_maskmem_pos_enc = None
        return expanded_maskmem_pos_enc

    def _clear_non_cond_mem_around_input(self, frame_idx, obj_idx=None):
        """
        Remove the non-conditioning memory around the input frame. When users provide
        correction clicks, the surrounding frames' non-conditioning memories can still
        contain outdated object appearance information and could confuse the model.

        This method clears those non-conditioning memories surrounding the interacted
        frame to avoid giving the model both old and new information about the object.
        """
        r = self.memory_temporal_stride_for_eval
        frame_idx_begin = frame_idx - r * self.num_maskmem
        frame_idx_end = frame_idx + r * self.num_maskmem
        if obj_idx is None:
            output_dicts = self.condition_state["output_dict_per_obj"].values()
        else:
            output_dicts = [self.condition_state["output_dict_per_obj"][obj_idx]]
        for t in range(frame_idx_begin, frame_idx_end + 1):
            for obj_output_dict in output_dicts:
                obj_output_dict["non_cond_frame_outputs"].pop(t, None)


class SAM2CameraPredictorVOS(SAM2CameraPredictor):
    """Optimized for the VOS setting"""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.compile_memory_encoder = kwargs.get("compile_memory_encoder", False)
        self.compile_memory_attention = kwargs.get("compile_memory_attention", False)
        self.compile_prompt_encoder = kwargs.get("compile_prompt_encoder", False)
        self.compile_mask_decoder = kwargs.get("compile_mask_decoder", False)
        self._compile_all_components()

    def _compile_all_components(self):
        print("Compiling all components for VOS setting. First time may be very slow.")
        if self.compile_memory_encoder:
            print("Compiling memory encoder...")
            self.memory_encoder.forward = torch.compile(
                self.memory_encoder.forward,
                mode="max-autotune",
                fullgraph=True,
                dynamic=False,
            )
        if self.compile_memory_attention:
            print("Compiling memory attention...")
            self.memory_attention.forward = torch.compile(
                self.memory_attention.forward,
                mode="max-autotune",
                fullgraph=True,
                dynamic=True,
            )
        if self.compile_prompt_encoder:
            self.sam_prompt_encoder.forward = torch.compile(
                self.sam_prompt_encoder.forward,
                mode="max-autotune",
                fullgraph=True,
                dynamic=False,  # Accuracy regression on True
            )
        if self.compile_mask_decoder:
            self.sam_mask_decoder.forward = torch.compile(
                self.sam_mask_decoder.forward,
                mode="max-autotune",
                fullgraph=True,
                dynamic=False,  # Accuracy regression on True
            )

    def forward_image(self, img_batch: torch.Tensor):
        """
        Identical to the corresponding method in the parent (SAM2VideoPredictor), but
        cloning the backbone features and pos encoding to enable compilation.
        """
        backbone_out = self.image_encoder(img_batch)
        if self.use_high_res_features_in_sam:
            # precompute projected level 0 and level 1 features in SAM decoder
            # to avoid running it again on every SAM click
            backbone_out["backbone_fpn"][0] = self.sam_mask_decoder.conv_s0(
                backbone_out["backbone_fpn"][0]
            )
            backbone_out["backbone_fpn"][1] = self.sam_mask_decoder.conv_s1(
                backbone_out["backbone_fpn"][1]
            )
        # Clone to help torch.compile
        for i in range(len(backbone_out["backbone_fpn"])):
            backbone_out["backbone_fpn"][i] = backbone_out["backbone_fpn"][i].clone()
            backbone_out["vision_pos_enc"][i] = backbone_out["vision_pos_enc"][
                i
            ].clone()
        return backbone_out

    def _forward_sam_heads(
        self,
        backbone_features,
        point_inputs=None,
        mask_inputs=None,
        high_res_features=None,
        multimask_output=False,
    ):
        """
        Identical to the corresponding method in the parent (SAM2VideoPredictor), but
        cloning the outputs of prompt_encoder and mask_decoder to enable compilation.
        """
        B = backbone_features.size(0)
        device = backbone_features.device
        assert backbone_features.size(1) == self.sam_prompt_embed_dim
        assert backbone_features.size(2) == self.sam_image_embedding_size
        assert backbone_features.size(3) == self.sam_image_embedding_size

        # a) Handle point prompts
        if point_inputs is not None:
            sam_point_coords = point_inputs["point_coords"]
            sam_point_labels = point_inputs["point_labels"]
            assert sam_point_coords.size(0) == B and sam_point_labels.size(0) == B
        else:
            # If no points are provide, pad with an empty point (with label -1)
            sam_point_coords = torch.zeros(B, 1, 2, device=device)
            sam_point_labels = -torch.ones(B, 1, dtype=torch.int32, device=device)

        # b) Handle mask prompts
        if mask_inputs is not None:
            # If mask_inputs is provided, downsize it into low-res mask input if needed
            # and feed it as a dense mask prompt into the SAM mask encoder
            assert len(mask_inputs.shape) == 4 and mask_inputs.shape[:2] == (B, 1)
            if mask_inputs.shape[-2:] != self.sam_prompt_encoder.mask_input_size:
                sam_mask_prompt = F.interpolate(
                    mask_inputs.float(),
                    size=self.sam_prompt_encoder.mask_input_size,
                    align_corners=False,
                    mode="bilinear",
                    antialias=True,  # use antialias for downsampling
                )
            else:
                sam_mask_prompt = mask_inputs
        else:
            # Otherwise, simply feed None (and SAM's prompt encoder will add
            # a learned `no_mask_embed` to indicate no mask input in this case).
            sam_mask_prompt = None

        sparse_embeddings, dense_embeddings = self.sam_prompt_encoder(
            points=(sam_point_coords, sam_point_labels),
            boxes=None,
            masks=sam_mask_prompt,
        )
        # Clone image_pe and the outputs of sam_prompt_encoder
        # to enable compilation
        sparse_embeddings = sparse_embeddings.clone()
        dense_embeddings = dense_embeddings.clone()
        image_pe = self.sam_prompt_encoder.get_dense_pe().clone()
        (
            low_res_multimasks,
            ious,
            sam_output_tokens,
            object_score_logits,
        ) = self.sam_mask_decoder(
            image_embeddings=backbone_features,
            image_pe=image_pe,
            sparse_prompt_embeddings=sparse_embeddings,
            dense_prompt_embeddings=dense_embeddings,
            multimask_output=multimask_output,
            repeat_image=False,  # the image is already batched
            high_res_features=high_res_features,
        )
        # Clone the output of sam_mask_decoder
        # to enable compilation
        low_res_multimasks = low_res_multimasks.clone()
        ious = ious.clone()
        sam_output_tokens = sam_output_tokens.clone()
        object_score_logits = object_score_logits.clone()

        if self.pred_obj_scores:
            is_obj_appearing = object_score_logits > 0

            # Mask used for spatial memories is always a *hard* choice between obj and no obj,
            # consistent with the actual mask prediction
            low_res_multimasks = torch.where(
                is_obj_appearing[:, None, None],
                low_res_multimasks,
                NO_OBJ_SCORE,
            )

        # convert masks from possibly bfloat16 (or float16) to float32
        # (older PyTorch versions before 2.1 don't support `interpolate` on bf16)
        low_res_multimasks = low_res_multimasks.float()
        high_res_multimasks = F.interpolate(
            low_res_multimasks,
            size=(self.image_size, self.image_size),
            mode="bilinear",
            align_corners=False,
        )

        sam_output_token = sam_output_tokens[:, 0]
        if multimask_output:
            # take the best mask prediction (with the highest IoU estimation)
            best_iou_inds = torch.argmax(ious, dim=-1)
            batch_inds = torch.arange(B, device=device)
            low_res_masks = low_res_multimasks[batch_inds, best_iou_inds].unsqueeze(1)
            high_res_masks = high_res_multimasks[batch_inds, best_iou_inds].unsqueeze(1)
            if sam_output_tokens.size(1) > 1:
                sam_output_token = sam_output_tokens[batch_inds, best_iou_inds]
        else:
            low_res_masks, high_res_masks = low_res_multimasks, high_res_multimasks

        # Extract object pointer from the SAM output token (with occlusion handling)
        obj_ptr = self.obj_ptr_proj(sam_output_token)
        if self.pred_obj_scores:
            # Allow *soft* no obj ptr, unlike for masks
            if self.soft_no_obj_ptr:
                lambda_is_obj_appearing = object_score_logits.sigmoid()
            else:
                lambda_is_obj_appearing = is_obj_appearing.float()

            if self.fixed_no_obj_ptr:
                obj_ptr = lambda_is_obj_appearing * obj_ptr
            obj_ptr = obj_ptr + (1 - lambda_is_obj_appearing) * self.no_obj_ptr

        return (
            low_res_multimasks,
            high_res_multimasks,
            ious,
            low_res_masks,
            high_res_masks,
            obj_ptr,
            object_score_logits,
        )

    def _encode_new_memory(
        self,
        current_vision_feats,
        feat_sizes,
        pred_masks_high_res,
        object_score_logits,
        is_mask_from_pts,
    ):
        """
        Identical to the corresponding method in the parent (SAM2VideoPredictor), but
        cloning the memories and their pos enc to enable compilation.
        """
        B = current_vision_feats[-1].size(1)  # batch size on this frame
        C = self.hidden_dim
        H, W = feat_sizes[-1]  # top-level (lowest-resolution) feature size
        # top-level feature, (HW)BC => BCHW
        pix_feat = current_vision_feats[-1].permute(1, 2, 0).view(B, C, H, W)
        if self.non_overlap_masks_for_mem_enc and not self.training:
            # optionally, apply non-overlapping constraints to the masks (it's applied
            # in the batch dimension and should only be used during eval, where all
            # the objects come from the same video under batch size 1).
            pred_masks_high_res = self._apply_non_overlapping_constraints(
                pred_masks_high_res
            )
        # scale the raw mask logits with a temperature before applying sigmoid
        binarize = self.binarize_mask_from_pts_for_mem_enc and is_mask_from_pts
        if binarize and not self.training:
            mask_for_mem = (pred_masks_high_res > 0).float()
        else:
            # apply sigmoid on the raw mask logits to turn them into range (0, 1)
            mask_for_mem = torch.sigmoid(pred_masks_high_res)
        # apply scale and bias terms to the sigmoid probabilities
        if self.sigmoid_scale_for_mem_enc != 1.0:
            mask_for_mem = mask_for_mem * self.sigmoid_scale_for_mem_enc
        if self.sigmoid_bias_for_mem_enc != 0.0:
            mask_for_mem = mask_for_mem + self.sigmoid_bias_for_mem_enc
        maskmem_out = self.memory_encoder(
            pix_feat, mask_for_mem, skip_mask_sigmoid=True  # sigmoid already applied
        )
        # Clone the feats and pos_enc to enable compilation
        maskmem_features = maskmem_out["vision_features"].clone()
        maskmem_pos_enc = [m.clone() for m in maskmem_out["vision_pos_enc"]]
        # add a no-object embedding to the spatial memory to indicate that the frame
        # is predicted to be occluded (i.e. no object is appearing in the frame)
        if self.no_obj_embed_spatial is not None:
            is_obj_appearing = (object_score_logits > 0).float()
            maskmem_features += (
                1 - is_obj_appearing[..., None, None]
            ) * self.no_obj_embed_spatial[..., None, None].expand(
                *maskmem_features.shape
            )

        return maskmem_features, maskmem_pos_enc
