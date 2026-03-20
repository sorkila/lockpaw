import { open, showHUD } from "@raycast/api";
import { showFailureToast } from "@raycast/utils";

export default async function Command() {
  try {
    await open("lockpaw://toggle");
    await showHUD("Lockpaw toggled");
  } catch {
    await showFailureToast("Failed to toggle. Is Lockpaw running?");
  }
}
