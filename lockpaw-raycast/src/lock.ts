import { open, showHUD } from "@raycast/api";

export default async function Command() {
  await open("lockpaw://lock");
  await showHUD("Lockpaw locked");
}
