import { open, showHUD } from "@raycast/api";

export default async function Command() {
  await open("lockpaw://toggle");
  await showHUD("Lockpaw toggled");
}
