import { open, showHUD } from "@raycast/api";

export default async function Command() {
  await open("lockpaw://unlock-password");
  await showHUD("Lockpaw password unlock requested");
}
