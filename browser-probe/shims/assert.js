export class AssertionError extends Error { constructor(opts) { super(typeof opts === 'string' ? opts : opts?.message ?? 'Assertion failed'); this.name = 'AssertionError'; } }
function assert(v, msg) { if (!v) throw new AssertionError(msg || 'Assertion failed'); }
assert.strict = assert; assert.ok = assert; assert.AssertionError = AssertionError;
assert.equal = (a,b,m)=>assert(a==b,m); assert.strictEqual=(a,b,m)=>assert(a===b,m); assert.fail=(m)=>{throw new AssertionError(m);};
export default assert; export { assert as ok, assert as strict };
