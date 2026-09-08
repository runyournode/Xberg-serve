import http from 'k6/http';
import { check } from 'k6';

const pdf = open('./cetonic_regime.pdf', 'b');

export const options = {
  scenarios: {
    extract: {
      executor: 'constant-vus',
      vus: 100,
      duration: '5m',
    },
  },
};

export default function () {
  const response = http.post(
    'http://127.0.0.1:8085/extract',
    {
      files: http.file(
        pdf,
        'cetonic_regime.pdf',
        'application/pdf'
      ),
    },
    {
      headers: {
        Accept: 'application/json',
      },
      timeout: '2m',
    }
  );

  check(response, {
    'HTTP 200': (r) => r.status === 200,
  });
}