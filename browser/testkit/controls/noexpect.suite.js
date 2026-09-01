// A CONTROL, NOT A TEST. Two tests: one asserts, one asserts nothing.
//
// The second is the shape of a test that silently stopped doing its job — a body that returned
// early, or read a renamed field as `undefined` and compared two absences. `runner.js` must fail it
// by name with `reason: 'no-expectations'`, and must still pass the first, so the rule is shown to
// be discriminating rather than merely strict.
export default async function register({ describe, it }) {
  describe('control', () => {
    it('asserts something', ({ expect }) => {
      expect(1 + 1).toBe(2);
    });
    it('asserts nothing at all', () => {
      // deliberately no expectation
    });
  });
}
