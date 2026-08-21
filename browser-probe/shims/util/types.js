export const isAnyArrayBuffer = (v) => v instanceof ArrayBuffer || (typeof SharedArrayBuffer !== "undefined" && v instanceof SharedArrayBuffer);
export default { isAnyArrayBuffer };
