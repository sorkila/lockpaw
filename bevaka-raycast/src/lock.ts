import { open, showHUD } from "@raycast/api";

export default async function Command() {
  await open("bevaka://lock");
  await showHUD("Bevaka locked");
}
