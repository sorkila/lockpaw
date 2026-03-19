import { open, showHUD } from "@raycast/api";

export default async function Command() {
  await open("bevaka://toggle");
  await showHUD("Bevaka toggled");
}
