import { open, showHUD } from "@raycast/api";
import { showFailureToast } from "@raycast/utils";

export default async function Command() {
  try {
    await open("lockpaw://unlock-password");
    await showHUD("Unlocking with password");
  } catch {
    await showFailureToast("Failed to unlock. Is Lockpaw running?");
  }
}
