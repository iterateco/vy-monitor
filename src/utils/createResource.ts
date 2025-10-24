export default function createResource<T>(fetcher: () => Promise<T>) {
  let status = 'pending';
  let result: T;
  const suspender = fetcher().then(
    r => {
      status = 'success';
      result = r;
    },
    e => {
      status = 'error';
      result = e;
    }
  );

  return {
    read() {
      if (status === 'pending') throw suspender;
      if (status === 'error') throw result;
      return result;
    }
  }
}
