import { open, showHUD } from "@raycast/api";
import { showFailureToast } from "@raycast/utils";

export default async function Command() {
  try {
    await open("lockpaw://lock");
    await showHUD("Lockpaw locked");
  } catch {
    await showFailureToast("Failed to lock. Is Lockpaw running?");
  }
}
