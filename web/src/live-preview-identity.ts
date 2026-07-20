export function isNonNegativeSafeInteger(value: unknown): value is number {
  return Number.isSafeInteger(value) && Number(value) >= 0;
}

export function isPositiveSafeInteger(value: unknown): value is number {
  return Number.isSafeInteger(value) && Number(value) > 0;
}

export function sourceRangeIsValid(
  from: unknown,
  to: unknown,
  documentLength: unknown,
  allowEmpty: boolean,
): boolean {
  if (
    !isNonNegativeSafeInteger(from) ||
    !isNonNegativeSafeInteger(to) ||
    !isNonNegativeSafeInteger(documentLength)
  ) {
    return false;
  }
  return from <= to && (allowEmpty || from < to) && to <= documentLength;
}
