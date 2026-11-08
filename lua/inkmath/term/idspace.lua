-- Kitty image id space, shared by the schema (validation) and term/images (allocation).
return {
  MAX = 0xFFFFFF, -- ids travel as the placeholder's 24-bit foreground
  INSTANCES = 224, -- image_ids.per_instance: slot base + (pid % INSTANCES) * span
}
