// M13 support — decode the contract-deployment logs with UPSTREAM'S OWN TypeScript readers.
//
// ADDED BY aztec-avm-runtime. It exists because a wire format re-derived downstream is a wire
// format that can drift away from upstream's silently, and the usual defence — encode and decode
// with the same code and check the round trip — proves only that our encoder and our decoder were
// written from the same page. Here the C++ driver (`avm_differential contractdbinputs`) prints the
// raw log FIELDS, and this script decodes those same fields with
// `ContractClassPublishedEvent.fromLog` and `ContractInstancePublishedEvent.fromLog` from the
// pinned `@aztec/protocol-contracts` npm package. Two independent decoders, one of them upstream's,
// over one set of bytes.
//
// It also catches the specific defect the C++ decoder's comment names: `FuzzerContractDB::from_logs`
// reads the instance log as (tag, version, address, ...) when upstream writes
// (tag, address, version, ...), and stops two public-key fields short. A decoder written to that
// layout disagrees with this script on the address, on `immutablesHash` and on two keys.
//
// Usage:  cd diffsim && node decode_deployment_logs.mjs <contractdbinputs-transcript>
//
// Prints `upstreamDecode.<program>.<field> <value>` lines in the same key/value shape the C++
// transcript uses, so the comparison is a join on keys rather than a parse of prose. Exit status is
// non-zero if any log fails to decode or the transcript carries no logs at all.

import fs from 'fs';

import { CONTRACT_CLASS_LOG_SIZE_IN_FIELDS } from '@aztec/constants';
import { ContractClassPublishedEvent } from '@aztec/protocol-contracts/class-registry';
import { ContractInstancePublishedEvent } from '@aztec/protocol-contracts/instance-registry';
import { Fr } from '@aztec/foundation/curves/bn254';
import { ContractClassLog, ContractClassLogFields, PrivateLog } from '@aztec/stdlib/logs';

const path = process.argv[2];
if (!path) {
  console.error('usage: node decode_deployment_logs.mjs <contractdbinputs-transcript>');
  process.exit(2);
}

/** `key value` lines into a Map. The transcript's own format; no other parsing is done. */
const transcript = new Map();
for (const line of fs.readFileSync(path, 'utf8').split('\n')) {
  if (!line) {
    continue;
  }
  const i = line.indexOf(' ');
  if (i < 0) {
    continue;
  }
  transcript.set(line.slice(0, i), line.slice(i + 1));
}

function fieldsAt(prefix) {
  const count = transcript.get(`${prefix}.count`);
  if (count === undefined) {
    throw new Error(`transcript carries no ${prefix}.count`);
  }
  const n = Number(count);
  const out = [];
  for (let i = 0; i < n; i++) {
    const v = transcript.get(`${prefix}.${i}`);
    if (v === undefined) {
      throw new Error(`transcript is missing ${prefix}.${i} of ${n}`);
    }
    out.push(Fr.fromHexString(v));
  }
  return out;
}

const programCount = Number(transcript.get('contractDbInputs.programs.count') ?? '0');
if (!programCount) {
  console.error('the transcript declares no programs — nothing to decode');
  process.exit(1);
}

const programs = new Set();
for (const key of transcript.keys()) {
  const m = /^contractDbInputs\.([^.]+)\.logs\.class\.count$/.exec(key);
  if (m) {
    programs.add(m[1]);
  }
}
if (programs.size !== programCount) {
  console.error(`the transcript declares ${programCount} programs but carries logs for ${programs.size}`);
  process.exit(1);
}

let decoded = 0;
for (const program of [...programs].sort()) {
  const out = k => `upstreamDecode.${program}.${k}`;
  // A real contract-class log is a FIXED-SIZE field array: the payload followed by zeros, and
  // `ContractClassLogFields` refuses any other length. The C++ driver prints the payload prefix
  // only — 3023 hex lines per program would make the transcript unreadable for no information —
  // so the zeros are restored here, using upstream's OWN constant rather than a number written
  // down on this side. Padding is semantically neutral to the reader being tested: `fromLog`
  // takes every field after the header as bytecode and then truncates to the byte length the log
  // itself declares, which is the field the driver emits.
  const classPayload = fieldsAt(`contractDbInputs.${program}.logs.class`);
  if (classPayload.length > CONTRACT_CLASS_LOG_SIZE_IN_FIELDS) {
    throw new Error(
      `${program}: class log payload is ${classPayload.length} fields, more than the ` +
        `${CONTRACT_CLASS_LOG_SIZE_IN_FIELDS} a contract class log can hold`,
    );
  }
  const classFields = classPayload.concat(
    Array.from({ length: CONTRACT_CLASS_LOG_SIZE_IN_FIELDS - classPayload.length }, () => Fr.ZERO),
  );
  const classLog = new ContractClassLog(Fr.ZERO, new ContractClassLogFields(classFields), classPayload.length);
  const instanceFields = fieldsAt(`contractDbInputs.${program}.logs.instance`);
  const instanceLog = new PrivateLog(instanceFields, instanceFields.length);

  const classEvent = ContractClassPublishedEvent.fromLog(classLog);
  const instanceEvent = ContractInstancePublishedEvent.fromLog(instanceLog);
  const instance = instanceEvent.toContractInstance();

  console.log(`${out('classId')} ${classEvent.contractClassId.toString()}`);
  console.log(`${out('artifactHash')} ${classEvent.artifactHash.toString()}`);
  console.log(`${out('privateFunctionsRoot')} ${classEvent.privateFunctionsRoot.toString()}`);
  console.log(`${out('bytecodeBytes')} ${classEvent.packedPublicBytecode.length}`);
  console.log(`${out('address')} ${instance.address.toString()}`);
  console.log(`${out('salt')} ${instance.salt.toString()}`);
  console.log(`${out('deployer')} ${instance.deployer.toString()}`);
  console.log(`${out('initializationHash')} ${instance.initializationHash.toString()}`);
  console.log(`${out('immutablesHash')} ${instance.immutablesHash.toString()}`);
  const keys = instance.publicKeys.toFields();
  for (let k = 0; k < keys.length; k++) {
    console.log(`${out(`publicKey.${k}`)} ${keys[k].toString()}`);
  }
  decoded++;
}

console.log(`upstreamDecode.programs ${decoded}`);
