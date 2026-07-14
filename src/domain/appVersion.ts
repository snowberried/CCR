export function compareAppVersions(left: string, right: string): number {
  const parse = (value: string) => value.replace(/^v/i, "").split(".").map((part) => Number(part));
  const leftParts = parse(left);
  const rightParts = parse(right);

  for (let index = 0; index < Math.max(leftParts.length, rightParts.length); index += 1) {
    const difference = (leftParts[index] ?? 0) - (rightParts[index] ?? 0);
    if (difference !== 0) return Math.sign(difference);
  }
  return 0;
}
