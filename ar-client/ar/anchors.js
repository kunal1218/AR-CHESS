function makeFallbackPose(seed = 0) {
  const wobble = ((seed % 20) - 10) / 500;
  return {
    pos: { x: wobble, y: 0, z: -1.1 },
    rot: { x: 0, y: 0, z: 0, w: 1 },
  };
}

export async function defaultAnchorResolver(cloudAnchorId) {
  if (!cloudAnchorId || cloudAnchorId.startsWith('fail-')) {
    return null;
  }

  return {
    cloud_anchor_id: cloudAnchorId,
    pose: makeFallbackPose(cloudAnchorId.length),
  };
}

export async function resolveCloudAnchors(cloudAnchorIds, resolver = defaultAnchorResolver) {
  for (const cloudAnchorId of cloudAnchorIds) {
    try {
      const resolved = await resolver(cloudAnchorId);
      if (resolved) {
        return resolved;
      }
    } catch (error) {
      console.warn(`Anchor resolve failed for ${cloudAnchorId}`, error);
    }
  }

  return null;
}

export async function submitHostedAnchor(cloud_anchor_id, pose) {
  return {
    accepted: true,
    cloud_anchor_id,
    pose,
    submitted_at: new Date().toISOString(),
    notes: 'Stubbed locally. Wire this to POST /v1/rooms/{room_id}/anchors during integration.',
  };
}
