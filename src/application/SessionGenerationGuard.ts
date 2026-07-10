export class SessionGenerationGuard {
  private generation = 0;

  begin(): number {
    this.generation += 1;
    return this.generation;
  }

  invalidate(): number {
    return this.begin();
  }

  isCurrent(generation: number): boolean {
    return generation === this.generation;
  }

  current(): number {
    return this.generation;
  }
}
