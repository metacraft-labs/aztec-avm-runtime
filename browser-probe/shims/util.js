export const inspect = Object.assign((o) => (typeof o === 'string' ? o : JSON.stringify(o)), { custom: Symbol.for('nodejs.util.inspect.custom') });
export const promisify = (f) => (...a) => new Promise((res, rej) => f(...a, (e, r) => (e ? rej(e) : res(r))));
export const format = (...a) => a.map(String).join(' ');
export default { inspect, promisify, format };
